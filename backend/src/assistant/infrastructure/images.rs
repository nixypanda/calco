//! Bounded normalization of untrusted food-photo uploads.

use std::io::Cursor;

use async_trait::async_trait;
use image::{ImageFormat, ImageReader, load_from_memory_with_format};

use crate::assistant::application::{
    FoodImageError, FoodImageLimits, FoodImageSanitizer, FoodPhotoMimeType, SanitizedFoodPhoto,
};

pub const MAX_FOOD_PHOTOS: usize = 4;
pub const MAX_FOOD_PHOTO_BYTES: usize = 5 * 1024 * 1024;
pub const MAX_FOOD_PHOTO_TOTAL_BYTES: usize = 12 * 1024 * 1024;
pub const MAX_FOOD_PHOTO_DIMENSION: u32 = 2_048;
pub const MAX_FOOD_PHOTO_PIXELS: u64 = 12_000_000;

pub struct SafeFoodImageSanitizer;

#[async_trait]
impl FoodImageSanitizer for SafeFoodImageSanitizer {
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
    ) -> Result<SanitizedFoodPhoto, FoodImageError> {
        let declared_mime_type = declared_mime_type.to_owned();
        tokio::task::spawn_blocking(move || sanitize_food_photo(&declared_mime_type, bytes))
            .await
            .map_err(|_| FoodImageError::Internal)?
    }
}

pub fn sanitize_food_photo(
    declared_mime_type: &str,
    bytes: Vec<u8>,
) -> Result<SanitizedFoodPhoto, FoodImageError> {
    if bytes.is_empty() {
        return Err(FoodImageError::Empty);
    }
    if bytes.len() > MAX_FOOD_PHOTO_BYTES {
        return Err(FoodImageError::EncodedTooLarge);
    }

    let mime_type = parse_mime_type(declared_mime_type)?;
    let detected = detect_format(&bytes).ok_or(FoodImageError::InvalidData)?;
    if detected != mime_type {
        return Err(FoodImageError::TypeMismatch);
    }

    let (width, height) = ImageReader::with_format(Cursor::new(&bytes), image_format(mime_type))
        .into_dimensions()
        .map_err(|_| FoodImageError::InvalidData)?;
    validate_dimensions(width, height)?;

    let decoded = load_from_memory_with_format(&bytes, image_format(mime_type))
        .map_err(|_| FoodImageError::InvalidData)?;
    validate_dimensions(decoded.width(), decoded.height())?;
    let normalized = if decoded.width() > MAX_FOOD_PHOTO_DIMENSION
        || decoded.height() > MAX_FOOD_PHOTO_DIMENSION
    {
        decoded.thumbnail(MAX_FOOD_PHOTO_DIMENSION, MAX_FOOD_PHOTO_DIMENSION)
    } else {
        decoded
    };
    let mut output = Cursor::new(Vec::new());
    normalized
        .write_to(&mut output, image_format(mime_type))
        .map_err(|_| FoodImageError::InvalidData)?;
    let bytes = output.into_inner();
    if bytes.is_empty() || bytes.len() > MAX_FOOD_PHOTO_BYTES {
        return Err(FoodImageError::EncodedTooLarge);
    }
    Ok(SanitizedFoodPhoto { mime_type, bytes })
}

fn parse_mime_type(value: &str) -> Result<FoodPhotoMimeType, FoodImageError> {
    match value {
        "image/jpeg" => Ok(FoodPhotoMimeType::Jpeg),
        "image/png" => Ok(FoodPhotoMimeType::Png),
        "image/webp" => Ok(FoodPhotoMimeType::Webp),
        _ => Err(FoodImageError::UnsupportedType),
    }
}

fn detect_format(bytes: &[u8]) -> Option<FoodPhotoMimeType> {
    if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some(FoodPhotoMimeType::Jpeg)
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some(FoodPhotoMimeType::Png)
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some(FoodPhotoMimeType::Webp)
    } else {
        None
    }
}

fn image_format(value: FoodPhotoMimeType) -> ImageFormat {
    match value {
        FoodPhotoMimeType::Jpeg => ImageFormat::Jpeg,
        FoodPhotoMimeType::Png => ImageFormat::Png,
        FoodPhotoMimeType::Webp => ImageFormat::WebP,
    }
}

fn validate_dimensions(width: u32, height: u32) -> Result<(), FoodImageError> {
    let pixels = u64::from(width)
        .checked_mul(u64::from(height))
        .ok_or(FoodImageError::DimensionsTooLarge)?;
    if width == 0 || height == 0 || pixels > MAX_FOOD_PHOTO_PIXELS {
        return Err(FoodImageError::DimensionsTooLarge);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use image::{DynamicImage, ImageBuffer, Rgba};

    use super::*;

    fn image_bytes(format: ImageFormat, width: u32, height: u32) -> Vec<u8> {
        let image = ImageBuffer::from_pixel(width, height, Rgba([20, 30, 40, 255]));
        let mut bytes = Cursor::new(Vec::new());
        DynamicImage::ImageRgba8(image)
            .write_to(&mut bytes, format)
            .unwrap();
        bytes.into_inner()
    }

    #[test]
    fn accepts_supported_formats_and_rejects_mismatches() {
        let png = image_bytes(ImageFormat::Png, 2, 3);
        assert_eq!(
            sanitize_food_photo("image/png", png.clone())
                .unwrap()
                .mime_type,
            FoodPhotoMimeType::Png
        );
        assert_eq!(
            sanitize_food_photo("image/jpeg", png.clone()),
            Err(FoodImageError::TypeMismatch)
        );
        assert_eq!(
            sanitize_food_photo("image/gif", png),
            Err(FoodImageError::UnsupportedType)
        );
        assert_eq!(
            sanitize_food_photo("image/png", b"not an image".to_vec()),
            Err(FoodImageError::InvalidData)
        );
    }

    #[test]
    fn strips_jpeg_metadata_and_downscales_large_images() {
        let encoded = image_bytes(ImageFormat::Jpeg, 3_000, 2_000);
        let marker = b"Exif\0\0calco-private-marker";
        let length = u16::try_from(marker.len() + 2).unwrap().to_be_bytes();
        let mut with_metadata = Vec::new();
        with_metadata.extend_from_slice(&encoded[..2]);
        with_metadata.extend_from_slice(&[0xff, 0xe1]);
        with_metadata.extend_from_slice(&length);
        with_metadata.extend_from_slice(marker);
        with_metadata.extend_from_slice(&encoded[2..]);

        let photo = sanitize_food_photo("image/jpeg", with_metadata).unwrap();
        assert!(
            !photo
                .bytes
                .windows(marker.len())
                .any(|value| value == marker)
        );
        let (width, height) = ImageReader::with_format(Cursor::new(photo.bytes), ImageFormat::Jpeg)
            .into_dimensions()
            .unwrap();
        assert!(width <= MAX_FOOD_PHOTO_DIMENSION && height <= MAX_FOOD_PHOTO_DIMENSION);
    }

    #[test]
    fn rejects_pixel_bombs_before_decode() {
        let png = image_bytes(ImageFormat::Png, 4_000, 4_000);
        assert_eq!(
            sanitize_food_photo("image/png", png),
            Err(FoodImageError::DimensionsTooLarge)
        );
    }
}
