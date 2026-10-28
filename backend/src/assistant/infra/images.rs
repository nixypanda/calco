//! Bounded normalization of untrusted food-photo uploads.

use std::io::Cursor;
use std::sync::Arc;

use async_trait::async_trait;
use image::{ImageFormat, ImageReader, Limits};
use tokio::sync::Semaphore;

use crate::assistant::app::{
    FoodImageLimits, FoodImageSanitizer, FoodPhotoMimeType, ImageError, SanitizedFoodPhoto,
};

pub const MAX_FOOD_PHOTOS: usize = 4;
pub const MAX_FOOD_PHOTO_BYTES: usize = 15 * 1024 * 1024;
pub const MAX_FOOD_PHOTO_TOTAL_BYTES: usize = 40 * 1024 * 1024;
pub const MAX_FOOD_PHOTO_DIMENSION: u32 = 2_048;
pub const MAX_FOOD_PHOTO_PIXELS: u64 = 50_000_000;
const MAX_DECODE_ALLOC_BYTES: u64 = 256 * 1024 * 1024;
const MAX_CONCURRENT_DECODES: usize = 1;

pub struct SafeImageSanitizer {
    decode_permits: Arc<Semaphore>,
}

impl SafeImageSanitizer {
    pub fn new() -> Self {
        Self {
            decode_permits: Arc::new(Semaphore::new(MAX_CONCURRENT_DECODES)),
        }
    }
}

impl Default for SafeImageSanitizer {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl FoodImageSanitizer for SafeImageSanitizer {
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
    ) -> Result<SanitizedFoodPhoto, ImageError> {
        let _decode_permit = self
            .decode_permits
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| ImageError::Internal)?;
        let declared_mime_type = declared_mime_type.to_owned();
        tokio::task::spawn_blocking(move || sanitize_food_photo(&declared_mime_type, bytes))
            .await
            .map_err(|_| ImageError::Internal)?
    }
}

pub fn sanitize_food_photo(
    declared_mime_type: &str,
    bytes: Vec<u8>,
) -> Result<SanitizedFoodPhoto, ImageError> {
    if bytes.is_empty() {
        return Err(ImageError::Empty);
    }
    if bytes.len() > MAX_FOOD_PHOTO_BYTES {
        return Err(ImageError::EncodedTooLarge);
    }

    let mime_type = parse_mime_type(declared_mime_type)?;
    let detected = detect_format(&bytes).ok_or(ImageError::InvalidData)?;
    if detected != mime_type {
        return Err(ImageError::TypeMismatch);
    }

    let (width, height) = ImageReader::with_format(Cursor::new(&bytes), image_format(mime_type))
        .into_dimensions()
        .map_err(|_| ImageError::InvalidData)?;
    validate_dimensions(width, height)?;

    let mut decoder = ImageReader::with_format(Cursor::new(&bytes), image_format(mime_type));
    let mut limits = Limits::default();
    limits.max_alloc = Some(MAX_DECODE_ALLOC_BYTES);
    decoder.limits(limits);
    let decoded = decoder.decode().map_err(|_| ImageError::InvalidData)?;
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
        .map_err(|_| ImageError::InvalidData)?;
    let bytes = output.into_inner();
    if bytes.is_empty() || bytes.len() > MAX_FOOD_PHOTO_BYTES {
        return Err(ImageError::EncodedTooLarge);
    }
    Ok(SanitizedFoodPhoto { mime_type, bytes })
}

fn parse_mime_type(value: &str) -> Result<FoodPhotoMimeType, ImageError> {
    match value {
        "image/jpeg" => Ok(FoodPhotoMimeType::Jpeg),
        "image/png" => Ok(FoodPhotoMimeType::Png),
        "image/webp" => Ok(FoodPhotoMimeType::Webp),
        _ => Err(ImageError::UnsupportedType),
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

fn validate_dimensions(width: u32, height: u32) -> Result<(), ImageError> {
    let pixels = u64::from(width)
        .checked_mul(u64::from(height))
        .ok_or(ImageError::DimensionsTooLarge)?;
    if width == 0 || height == 0 || pixels > MAX_FOOD_PHOTO_PIXELS {
        return Err(ImageError::DimensionsTooLarge);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use image::codecs::jpeg::JpegEncoder;
    use image::{DynamicImage, ImageBuffer, Rgba};
    use proptest::prelude::*;
    use rstest::rstest;

    use super::*;

    fn image_bytes(format: ImageFormat, width: u32, height: u32) -> Vec<u8> {
        let image = ImageBuffer::from_pixel(width, height, Rgba([20, 30, 40, 255]));
        let mut bytes = Cursor::new(Vec::new());
        if format == ImageFormat::Jpeg {
            let encoder = JpegEncoder::new_with_quality(&mut bytes, 50);
            DynamicImage::ImageRgba8(image)
                .write_with_encoder(encoder)
                .unwrap();
        } else {
            DynamicImage::ImageRgba8(image)
                .write_to(&mut bytes, format)
                .unwrap();
        }
        bytes.into_inner()
    }

    fn mime_for(format: ImageFormat) -> &'static str {
        match format {
            ImageFormat::Jpeg => "image/jpeg",
            ImageFormat::Png => "image/png",
            ImageFormat::WebP => "image/webp",
            other => panic!("unsupported test image format: {other:?}"),
        }
    }

    fn jpeg_with_app1_segment(encoded: Vec<u8>, marker: &[u8]) -> Vec<u8> {
        let length = u16::try_from(marker.len() + 2).unwrap().to_be_bytes();
        let mut with_metadata = Vec::with_capacity(encoded.len() + marker.len() + 4);
        with_metadata.extend_from_slice(&encoded[..2]);
        with_metadata.extend_from_slice(&[0xff, 0xe1]);
        with_metadata.extend_from_slice(&length);
        with_metadata.extend_from_slice(marker);
        with_metadata.extend_from_slice(&encoded[2..]);
        with_metadata
    }

    fn assert_output_invariants(
        declared_mime_type: &str,
        photo: &SanitizedFoodPhoto,
    ) -> (u32, u32) {
        assert_eq!(
            Some(photo.mime_type),
            parse_mime_type(declared_mime_type).ok()
        );
        assert_eq!(detect_format(&photo.bytes), Some(photo.mime_type));
        assert!(!photo.bytes.is_empty());
        assert!(photo.bytes.len() <= MAX_FOOD_PHOTO_BYTES);

        let decoded =
            ImageReader::with_format(Cursor::new(&photo.bytes), image_format(photo.mime_type))
                .decode()
                .expect("sanitized output must decode as its declared format");
        let (width, height) = (decoded.width(), decoded.height());
        assert!(width > 0 && height > 0);
        assert!(width <= MAX_FOOD_PHOTO_DIMENSION);
        assert!(height <= MAX_FOOD_PHOTO_DIMENSION);
        assert!(u64::from(width) * u64::from(height) <= MAX_FOOD_PHOTO_PIXELS);
        (width, height)
    }

    fn assert_dimensions_preserved(input: (u32, u32), output: (u32, u32)) {
        let (input_width, input_height) = input;
        let (width, height) = output;
        if input_width <= MAX_FOOD_PHOTO_DIMENSION && input_height <= MAX_FOOD_PHOTO_DIMENSION {
            assert_eq!(output, input, "in-bounds image must not be resized");
            return;
        }

        assert_eq!(
            width.max(height),
            MAX_FOOD_PHOTO_DIMENSION,
            "over-limit image must be scaled to the maximum dimension"
        );
        let scale = f64::from(MAX_FOOD_PHOTO_DIMENSION) / f64::from(input_width.max(input_height));
        let expected_width = (f64::from(input_width) * scale).round().max(1.0) as u32;
        let expected_height = (f64::from(input_height) * scale).round().max(1.0) as u32;
        assert!(
            width.abs_diff(expected_width) <= 1,
            "width {width} does not preserve {input_width}x{input_height} within 1 px \
             (expected {expected_width})"
        );
        assert!(
            height.abs_diff(expected_height) <= 1,
            "height {height} does not preserve {input_width}x{input_height} within 1 px \
             (expected {expected_height})"
        );
    }

    fn supported_formats() -> impl Strategy<Value = ImageFormat> {
        prop_oneof![
            Just(ImageFormat::Png),
            Just(ImageFormat::Jpeg),
            Just(ImageFormat::WebP),
        ]
    }

    fn arbitrary_photo_input() -> impl Strategy<Value = (String, Vec<u8>)> {
        let arbitrary_bytes = (
            prop_oneof![
                Just("image/jpeg".to_owned()),
                Just("image/png".to_owned()),
                Just("image/webp".to_owned()),
                "[ -~]{0,40}",
            ],
            prop::collection::vec(any::<u8>(), 0..=4_096),
        );
        let encoded_small_image =
            (supported_formats(), 1u32..=32, 1u32..=32).prop_map(|(format, width, height)| {
                (
                    mime_for(format).to_owned(),
                    image_bytes(format, width, height),
                )
            });
        prop_oneof![
            1 => arbitrary_bytes,
            1 => encoded_small_image,
        ]
    }

    fn dimension_pairs() -> impl Strategy<Value = (u32, u32)> {
        const TEST_MAX_DIMENSION: u32 = MAX_FOOD_PHOTO_DIMENSION + 152;
        let boundary = (MAX_FOOD_PHOTO_DIMENSION - 1)..=TEST_MAX_DIMENSION;
        prop_oneof![
            // Mostly small images so the property runs quickly.
            8 => (1u32..=256, 1u32..=256),
            // Long, thin images exercise downscaling without allocating much.
            4 => (1u32..=256, boundary.clone()),
            4 => (boundary, 1u32..=256),
            // A few fully random images also cover two-dimensional downscaling.
            1 => (1u32..=TEST_MAX_DIMENSION, 1u32..=TEST_MAX_DIMENSION),
        ]
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(64))]

        #[test]
        fn arbitrary_input_never_panics_and_successes_satisfy_invariants(
            (declared_mime_type, bytes) in arbitrary_photo_input(),
        ) {
            match sanitize_food_photo(&declared_mime_type, bytes) {
                Ok(photo) => {
                    assert_output_invariants(&declared_mime_type, &photo);
                }
                Err(error) => {
                    // ImageError is a closed enum; enumerate every variant so a new
                    // variant forces this test to be reviewed.
                    match error {
                        ImageError::NotSupported
                        | ImageError::Empty
                        | ImageError::UnsupportedType
                        | ImageError::TypeMismatch
                        | ImageError::InvalidData
                        | ImageError::DimensionsTooLarge
                        | ImageError::EncodedTooLarge
                        | ImageError::Internal => {}
                    }
                }
            }
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(32))]

        #[test]
        fn structured_images_are_downscaled_within_bounds(
            format in supported_formats(),
            (width, height) in dimension_pairs(),
        ) {
            let declared_mime_type = mime_for(format);
            let bytes = image_bytes(format, width, height);
            let photo = sanitize_food_photo(declared_mime_type, bytes)
                .expect("generated supported image must sanitize");
            let output = assert_output_invariants(declared_mime_type, &photo);
            assert_dimensions_preserved((width, height), output);
        }
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
            Err(ImageError::TypeMismatch)
        );
        assert_eq!(
            sanitize_food_photo("image/gif", png),
            Err(ImageError::UnsupportedType)
        );
        assert_eq!(
            sanitize_food_photo("image/png", b"not an image".to_vec()),
            Err(ImageError::InvalidData)
        );
        assert_eq!(
            sanitize_food_photo("image/png", b"GIF89a\x01\x00\x01\x00".to_vec()),
            Err(ImageError::InvalidData)
        );
        assert_eq!(
            sanitize_food_photo("image/bmp", b"BM\x1a\x00\x00\x00".to_vec()),
            Err(ImageError::UnsupportedType)
        );
    }

    #[test]
    #[ignore = "slow"]
    fn strips_jpeg_metadata_and_downscales_large_images() {
        // A common 12 MP phone-camera resolution that exceeded the old limit.
        let encoded = image_bytes(ImageFormat::Jpeg, 2_500, 2_000);
        let marker = b"Exif\0\0calco-private-marker";
        let with_metadata = jpeg_with_app1_segment(encoded, marker);
        assert!(
            with_metadata
                .windows(marker.len())
                .any(|value| value == marker),
            "metadata helper must insert the marker before sanitizing"
        );

        let photo = sanitize_food_photo("image/jpeg", with_metadata).unwrap();
        assert!(
            !photo
                .bytes
                .windows(marker.len())
                .any(|value| value == marker)
        );
        let (width, height) = assert_output_invariants("image/jpeg", &photo);
        assert_eq!((width, height), (MAX_FOOD_PHOTO_DIMENSION, 1_638));
    }

    #[test]
    fn accepts_modern_phone_dimensions_and_rejects_larger_images() {
        assert_eq!(validate_dimensions(4_032, 3_024), Ok(()));
        assert_eq!(validate_dimensions(8_160, 6_120), Ok(()));
        assert_eq!(
            validate_dimensions(8_192, 6_144),
            Err(ImageError::DimensionsTooLarge)
        );
    }

    #[test]
    fn rejects_empty_and_oversized_inputs() {
        assert_eq!(
            sanitize_food_photo("image/png", Vec::new()),
            Err(ImageError::Empty)
        );
        assert_eq!(
            sanitize_food_photo("image/png", vec![0; MAX_FOOD_PHOTO_BYTES + 1]),
            Err(ImageError::EncodedTooLarge)
        );
    }

    #[rstest]
    #[case("image/png", ImageFormat::Png, Ok(FoodPhotoMimeType::Png))]
    #[case("image/png", ImageFormat::Jpeg, Err(ImageError::TypeMismatch))]
    #[case("image/png", ImageFormat::WebP, Err(ImageError::TypeMismatch))]
    #[case("image/jpeg", ImageFormat::Png, Err(ImageError::TypeMismatch))]
    #[case("image/jpeg", ImageFormat::Jpeg, Ok(FoodPhotoMimeType::Jpeg))]
    #[case("image/jpeg", ImageFormat::WebP, Err(ImageError::TypeMismatch))]
    #[case("image/webp", ImageFormat::Png, Err(ImageError::TypeMismatch))]
    #[case("image/webp", ImageFormat::Jpeg, Err(ImageError::TypeMismatch))]
    #[case("image/webp", ImageFormat::WebP, Ok(FoodPhotoMimeType::Webp))]
    #[case("image/gif", ImageFormat::Png, Err(ImageError::UnsupportedType))]
    #[case("image/gif", ImageFormat::Jpeg, Err(ImageError::UnsupportedType))]
    #[case("image/gif", ImageFormat::WebP, Err(ImageError::UnsupportedType))]
    fn accepts_matching_mime_and_rejects_every_format_mismatch(
        #[case] declared_mime_type: &str,
        #[case] actual_format: ImageFormat,
        #[case] expected: Result<FoodPhotoMimeType, ImageError>,
    ) {
        let result = sanitize_food_photo(declared_mime_type, image_bytes(actual_format, 5, 4));
        match expected {
            Ok(expected_mime_type) => {
                let photo = result.expect("matching mime type must be accepted");
                assert_eq!(photo.mime_type, expected_mime_type);
                assert_output_invariants(declared_mime_type, &photo);
            }
            Err(expected_error) => assert_eq!(result, Err(expected_error)),
        }
    }

    #[rstest]
    #[case(
        ImageFormat::Png,
        MAX_FOOD_PHOTO_DIMENSION,
        MAX_FOOD_PHOTO_DIMENSION,
        (MAX_FOOD_PHOTO_DIMENSION, MAX_FOOD_PHOTO_DIMENSION)
    )]
    #[case(
        ImageFormat::Png,
        MAX_FOOD_PHOTO_DIMENSION + 1,
        MAX_FOOD_PHOTO_DIMENSION + 1,
        (MAX_FOOD_PHOTO_DIMENSION, MAX_FOOD_PHOTO_DIMENSION)
    )]
    #[case(
        ImageFormat::Png,
        MAX_FOOD_PHOTO_DIMENSION + 52,
        64,
        (MAX_FOOD_PHOTO_DIMENSION, 62)
    )]
    fn keeps_boundary_dimensions_and_downscales_thin_over_limit_images(
        #[case] format: ImageFormat,
        #[case] width: u32,
        #[case] height: u32,
        #[case] expected: (u32, u32),
    ) {
        let declared_mime_type = mime_for(format);
        let photo = sanitize_food_photo(declared_mime_type, image_bytes(format, width, height))
            .expect("supported image must sanitize");
        let output = assert_output_invariants(declared_mime_type, &photo);
        assert_eq!(output, expected);
        assert_dimensions_preserved((width, height), output);
    }

    #[rstest]
    #[case(ImageFormat::WebP, 2_500, 2_500, (2_048, 2_048))]
    #[case(ImageFormat::Jpeg, 4_032, 3_024, (2_048, 1_536))]
    #[ignore = "slow"]
    fn downscales_slow_large_images_to_expected_dimensions(
        #[case] format: ImageFormat,
        #[case] width: u32,
        #[case] height: u32,
        #[case] expected: (u32, u32),
    ) {
        let declared_mime_type = mime_for(format);
        let photo = sanitize_food_photo(declared_mime_type, image_bytes(format, width, height))
            .expect("large supported image must sanitize");
        let output = assert_output_invariants(declared_mime_type, &photo);
        assert_eq!(output, expected);
        assert_dimensions_preserved((width, height), output);
    }

    #[test]
    fn strips_jpeg_metadata_from_small_images() {
        let marker = b"Exif\0\0calco-small-private-marker";
        let with_metadata = jpeg_with_app1_segment(image_bytes(ImageFormat::Jpeg, 64, 48), marker);
        assert!(
            with_metadata
                .windows(marker.len())
                .any(|value| value == marker),
            "metadata helper must insert the marker before sanitizing"
        );
        let photo = sanitize_food_photo("image/jpeg", with_metadata).unwrap();
        assert!(
            !photo
                .bytes
                .windows(marker.len())
                .any(|value| value == marker)
        );
        assert_output_invariants("image/jpeg", &photo);
    }
}
