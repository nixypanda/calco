//! Safe conversion of untrusted multipart food photos into provider input.
//!
//! Images are decoded only after a MIME type and file-signature check, bounded
//! before allocation, stripped of metadata by re-encoding, and never logged or
//! persisted. The output value is provider-neutral.

use std::io::Cursor;

use async_trait::async_trait;
use image::{DynamicImage, ImageFormat, ImageReader, load_from_memory_with_format};

use crate::assistant::application::{
    FoodImageLimits, FoodImageSanitizerPort, FoodPhotoMimeType, SanitizedFoodPhoto,
};
use crate::assistant::domain::AssistantError;

/// Product limits, deliberately code-owned rather than deployment settings.
pub const MAX_FOOD_PHOTOS: usize = 4;
pub const MAX_FOOD_PHOTO_BYTES: usize = 5 * 1024 * 1024;
pub const MAX_FOOD_PHOTO_TOTAL_BYTES: usize = 12 * 1024 * 1024;
pub const MAX_FOOD_PHOTO_DIMENSION: u32 = 2_048;
pub const MAX_FOOD_PHOTO_PIXELS: u64 = 12_000_000;

/// The production sanitizer. It has no storage, tracing, or provider client.
pub struct SafeFoodImageSanitizer;

#[async_trait]
impl FoodImageSanitizerPort for SafeFoodImageSanitizer {
    fn limits(&self) -> FoodImageLimits {
        FoodImageLimits {
            max_images: MAX_FOOD_PHOTOS,
            max_bytes_per_image: MAX_FOOD_PHOTO_BYTES,
            max_total_bytes: MAX_FOOD_PHOTO_TOTAL_BYTES,
        }
    }

    async fn sanitize(
        &self,
        declared_mime_type: &str,
        bytes: Vec<u8>,
    ) -> Result<SanitizedFoodPhoto, AssistantError> {
        let declared_mime_type = declared_mime_type.to_owned();
        tokio::task::spawn_blocking(move || sanitize_food_photo(&declared_mime_type, bytes))
            .await
            .map_err(|_| AssistantError::Internal)?
    }
}

pub fn sanitize_food_photo(
    declared_mime_type: &str,
    bytes: Vec<u8>,
) -> Result<SanitizedFoodPhoto, AssistantError> {
    if bytes.is_empty() || bytes.len() > MAX_FOOD_PHOTO_BYTES {
        return Err(invalid_photo("photo is too large or empty"));
    }

    let mime_type = parse_declared_mime_type(declared_mime_type)?;
    let format = format_from_signature(&bytes).ok_or_else(|| invalid_photo("unsupported photo"))?;
    if format != mime_type {
        return Err(invalid_photo("photo MIME type does not match its content"));
    }

    let (width, height) =
        dimensions(&bytes, format).map_err(|_| invalid_photo("invalid image data"))?;
    validate_dimensions(width, height)?;

    let decoded = load_from_memory_with_format(&bytes, image_format(format))
        .map_err(|_| invalid_photo("invalid image data"))?;
    // Check the decoded value too: malformed metadata must not bypass the
    // preflight parser's dimensions.
    validate_dimensions(decoded.width(), decoded.height())?;
    let normalized = downscale(decoded);
    let mut output = Cursor::new(Vec::new());
    normalized
        .write_to(&mut output, image_format(format))
        .map_err(|_| invalid_photo("could not normalize image"))?;
    let bytes = output.into_inner();
    if bytes.is_empty() || bytes.len() > MAX_FOOD_PHOTO_BYTES {
        return Err(invalid_photo("normalized photo is too large"));
    }

    Ok(SanitizedFoodPhoto { mime_type, bytes })
}

fn parse_declared_mime_type(value: &str) -> Result<FoodPhotoMimeType, AssistantError> {
    match value {
        "image/jpeg" => Ok(FoodPhotoMimeType::Jpeg),
        "image/png" => Ok(FoodPhotoMimeType::Png),
        "image/webp" => Ok(FoodPhotoMimeType::Webp),
        _ => Err(invalid_photo("photos must be JPEG, PNG, or WebP")),
    }
}

fn format_from_signature(bytes: &[u8]) -> Option<FoodPhotoMimeType> {
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some(FoodPhotoMimeType::Jpeg)
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some(FoodPhotoMimeType::Png)
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some(FoodPhotoMimeType::Webp)
    } else {
        None
    }
}

fn image_format(mime_type: FoodPhotoMimeType) -> ImageFormat {
    match mime_type {
        FoodPhotoMimeType::Jpeg => ImageFormat::Jpeg,
        FoodPhotoMimeType::Png => ImageFormat::Png,
        FoodPhotoMimeType::Webp => ImageFormat::WebP,
    }
}

fn dimensions(bytes: &[u8], mime_type: FoodPhotoMimeType) -> image::ImageResult<(u32, u32)> {
    ImageReader::with_format(Cursor::new(bytes), image_format(mime_type)).into_dimensions()
}

fn validate_dimensions(width: u32, height: u32) -> Result<(), AssistantError> {
    let pixels = u64::from(width)
        .checked_mul(u64::from(height))
        .ok_or_else(|| invalid_photo("image dimensions are invalid"))?;
    if width == 0 || height == 0 || pixels > MAX_FOOD_PHOTO_PIXELS {
        return Err(invalid_photo("photo dimensions exceed the limit"));
    }
    Ok(())
}

fn downscale(image: DynamicImage) -> DynamicImage {
    if image.width() > MAX_FOOD_PHOTO_DIMENSION || image.height() > MAX_FOOD_PHOTO_DIMENSION {
        image.thumbnail(MAX_FOOD_PHOTO_DIMENSION, MAX_FOOD_PHOTO_DIMENSION)
    } else {
        image
    }
}

fn invalid_photo(message: &'static str) -> AssistantError {
    AssistantError::Validation(message.into())
}

#[cfg(test)]
mod tests {
    use image::{ImageBuffer, Rgba};

    use super::*;

    fn png(width: u32, height: u32) -> Vec<u8> {
        let image = ImageBuffer::from_pixel(width, height, Rgba([20, 30, 40, 255]));
        let mut bytes = Cursor::new(Vec::new());
        DynamicImage::ImageRgba8(image)
            .write_to(&mut bytes, ImageFormat::Png)
            .unwrap();
        bytes.into_inner()
    }

    fn jpeg_with_exif_marker() -> Vec<u8> {
        let image = ImageBuffer::from_pixel(8, 6, Rgba([20, 30, 40, 255]));
        let mut encoded = Cursor::new(Vec::new());
        DynamicImage::ImageRgba8(image)
            .write_to(&mut encoded, ImageFormat::Jpeg)
            .unwrap();
        let encoded = encoded.into_inner();
        let marker = b"Exif\0\0calco-private-exif-marker";
        let segment_length = u16::try_from(marker.len() + 2).unwrap().to_be_bytes();
        let mut with_metadata = Vec::with_capacity(encoded.len() + marker.len() + 4);
        with_metadata.extend_from_slice(&encoded[..2]);
        with_metadata.extend_from_slice(&[0xFF, 0xE1]);
        with_metadata.extend_from_slice(&segment_length);
        with_metadata.extend_from_slice(marker);
        with_metadata.extend_from_slice(&encoded[2..]);
        with_metadata
    }

    #[test]
    fn reencoding_removes_injected_jpeg_exif_metadata() {
        let source = jpeg_with_exif_marker();
        assert!(
            source
                .windows(b"calco-private-exif-marker".len())
                .any(|window| { window == b"calco-private-exif-marker" })
        );

        let photo = sanitize_food_photo("image/jpeg", source).unwrap();
        assert_eq!(photo.mime_type, FoodPhotoMimeType::Jpeg);
        assert!(
            !photo
                .bytes
                .windows(b"calco-private-exif-marker".len())
                .any(|window| window == b"calco-private-exif-marker")
        );
        assert_eq!(
            dimensions(&photo.bytes, FoodPhotoMimeType::Jpeg).unwrap(),
            (8, 6)
        );
    }

    #[test]
    fn rejects_unsupported_or_mismatched_mime_and_signature() {
        let bytes = png(1, 1);
        for mime in ["image/gif", "image/jpeg", ""] {
            assert!(sanitize_food_photo(mime, bytes.clone()).is_err());
        }
        assert!(sanitize_food_photo("image/png", b"not an image".to_vec()).is_err());
    }

    #[test]
    fn downscales_but_rejects_pixel_bombs_before_decode() {
        let photo = sanitize_food_photo("image/png", png(3_000, 2_000)).unwrap();
        assert!(
            dimensions(&photo.bytes, FoodPhotoMimeType::Png).unwrap().0 <= MAX_FOOD_PHOTO_DIMENSION
        );
        assert!(sanitize_food_photo("image/png", png(4_000, 4_000)).is_err());
    }
}
