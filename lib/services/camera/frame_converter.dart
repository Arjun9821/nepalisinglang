import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// Converts a live [CameraImage] frame into an upright RGB [img.Image].
///
/// The `camera` plugin streams YUV420 on Android and BGRA8888 on iOS; both are
/// normalized to RGB and rotated upright using the sensor's mounted orientation,
/// since raw sensor frames are landscape whatever the device orientation.
img.Image convertCameraImageToImage(CameraImage image, int sensorOrientation) {
  final img.Image converted;
  switch (image.format.group) {
    case ImageFormatGroup.yuv420:
      converted = _convertYUV420(image);
      break;
    case ImageFormatGroup.bgra8888:
      converted = _convertBGRA8888(image);
      break;
    default:
      throw UnsupportedError(
        'Unsupported camera image format: ${image.format.group}',
      );
  }

  switch (sensorOrientation) {
    case 90:
      return img.copyRotate(converted, angle: 90);
    case 180:
      return img.copyRotate(converted, angle: 180);
    case 270:
      return img.copyRotate(converted, angle: 270);
    default:
      return converted;
  }
}

img.Image _convertYUV420(CameraImage image) {
  final width = image.width;
  final height = image.height;
  final out = img.Image(width: width, height: height, numChannels: 3);

  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];
  final yRowStride = yPlane.bytesPerRow;
  final uvRowStride = uPlane.bytesPerRow;
  final uvPixelStride = uPlane.bytesPerPixel ?? 1;

  for (int y = 0; y < height; y++) {
    final yRow = y * yRowStride;
    final uvRow = (y >> 1) * uvRowStride;
    for (int x = 0; x < width; x++) {
      final yValue = yPlane.bytes[yRow + x];
      final uvIndex = uvRow + (x >> 1) * uvPixelStride;
      final uValue = uPlane.bytes[uvIndex];
      final vValue = vPlane.bytes[uvIndex];

      final r = (yValue + 1.402 * (vValue - 128)).round().clamp(0, 255);
      final g = (yValue -
              0.344136 * (uValue - 128) -
              0.714136 * (vValue - 128))
          .round()
          .clamp(0, 255);
      final b = (yValue + 1.772 * (uValue - 128)).round().clamp(0, 255);

      out.setPixelRgb(x, y, r, g, b);
    }
  }
  return out;
}

img.Image _convertBGRA8888(CameraImage image) {
  final plane = image.planes[0];
  return img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: plane.bytes.buffer,
    bytesOffset: plane.bytes.offsetInBytes,
    rowStride: plane.bytesPerRow,
    order: img.ChannelOrder.bgra,
  );
}
