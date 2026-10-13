import 'package:go_router/go_router.dart';

import '../../presentation/widgets/root_scaffold.dart';

/// App-wide router.
///
/// The tabs are an [IndexedStack] inside [RootScaffold] driven by Riverpod
/// rather than separate go_router routes, so camera controllers survive tab
/// switches. go_router is still wired in at the top level so deep linking can be
/// added later without restructuring navigation.
final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const RootScaffold(),
    ),
  ],
);