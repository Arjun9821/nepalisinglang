import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Large rounded camera preview at the height fraction the caller specifies,
/// with loading and error states (e.g. permission denied).
class CameraPreviewCard extends StatelessWidget {
  final CameraController? controller;
  final double heightFraction;
  final String? errorMessage;

  /// Whether this screen currently owns the single shared camera. When false the
  /// camera has been released, so show a placeholder rather than a spinner that
  /// would never resolve.
  final bool isActive;

  const CameraPreviewCard({
    super.key,
    required this.controller,
    required this.heightFraction,
    this.errorMessage,
    this.isActive = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = MediaQuery.of(context).size.height * heightFraction;

    return Container(
      width: double.infinity,
      height: height,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildContent(theme),
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_rounded,
                  color: Colors.white70, size: 40),
              const SizedBox(height: 12),
              Text(
                errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

    if (!isActive) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.camera_alt_outlined, color: Colors.white70, size: 40),
              SizedBox(height: 12),
              Text(
                'Camera is paused. Select Live to reactivate it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

    if (controller == null || !controller!.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }

    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: controller!.value.previewSize?.height ?? 1,
        height: controller!.value.previewSize?.width ?? 1,
        child: CameraPreview(controller!),
      ),
    );
  }
}