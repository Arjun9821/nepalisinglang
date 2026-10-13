import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/constants.dart';
import '../providers/providers.dart';

/// Landing page — app branding, short description, and two entry cards
/// into the Live and Learn tabs.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // App logo placeholder
              Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.sign_language_rounded,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                AppConstants.appName,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                AppConstants.appShortDescription,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 32),
              const _AboutNslSection(),
              const SizedBox(height: 32),
              _ModeCard(
                icon: Icons.wifi_off_rounded,
                title: 'Start Recognising',
                subtitle: 'On-device recognition using TensorFlow Lite',
                color: theme.colorScheme.primary,
                onTap: () => ref.read(bottomNavIndexProvider.notifier).state =
                    AppConstants.liveTabIndex,
              ),
              const SizedBox(height: 16),
              _ModeCard(
                icon: Icons.wifi_rounded,
                title: 'Learn the Signs',
                subtitle: 'Cloud-based recognition via API',
                color: theme.colorScheme.secondary,
                onTap: () => ref.read(bottomNavIndexProvider.notifier).state =
                    AppConstants.learnTabIndex,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Single "About" card describing Nepali Sign Language, with a toggle that
/// switches the body text between English and Nepali.
class _AboutNslSection extends StatefulWidget {
  const _AboutNslSection();

  @override
  State<_AboutNslSection> createState() => _AboutNslSectionState();
}

class _AboutNslSectionState extends State<_AboutNslSection> {
  bool _showNepali = false;

  static const _englishText =
      'Nepali Sign Language (NSL) is the primary visual language '
      'used by the Deaf community in Nepal. It has its own grammar, '
      'vocabulary, and structure — distinct from spoken or written '
      'Nepali. This app recognizes NSL hand gestures in real time, '
      'helping bridge communication between Deaf and hearing users, '
      'both online and offline.';

  static const _nepaliText =
      'नेपाली साङ्केतिक भाषा (NSL) नेपालका बहिरा समुदायद्वारा प्रयोग '
      'गरिने प्रमुख दृश्य भाषा हो। यसको आफ्नै व्याकरण, शब्दभण्डार र '
      'संरचना छ — बोलिने वा लेखिने नेपाली भाषाभन्दा फरक। यो एपले '
      'वास्तविक समयमा NSL का इसाराहरू पहिचान गर्दछ, जसले बहिरा र '
      'सुन्न सक्ने प्रयोगकर्ताहरूबीच सञ्चारलाई सहज बनाउँछ — अनलाइन '
      'र अफलाइन दुवै अवस्थामा।';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'About',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _showNepali = !_showNepali),
                  icon: const Icon(Icons.translate_rounded, size: 18),
                  label: Text(_showNepali ? 'English' : 'नेपाली'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _showNepali ? _nepaliText : _englishText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: _showNepali ? 1.8 : 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios_rounded,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}