import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/library/presentation/bookshelf_page.dart';
import '../features/reader/presentation/reader_page.dart';
import '../features/settings/presentation/settings_page.dart';

/// 阅读页使用根 Navigator，全屏覆盖书架
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// 声明式路由（计划书 §3.1：go_router）
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    navigatorKey: rootNavigatorKey,
    routes: [
      GoRoute(
        path: '/',
        name: 'bookshelf',
        pageBuilder: (context, state) => CustomTransitionPage(
          key: state.pageKey,
          child: const BookshelfPage(),
          transitionsBuilder: (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      ),
      GoRoute(
        path: '/settings',
        name: 'settings',
        pageBuilder: (context, state) => CustomTransitionPage(
          key: state.pageKey,
          child: const SettingsPage(),
          transitionsBuilder: (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      ),
      GoRoute(
        path: '/reader/:bookId',
        name: 'reader',
        pageBuilder: (context, state) => CustomTransitionPage(
          key: state.pageKey,
          child: ReaderPage(bookId: state.pathParameters['bookId']!),
          transitionDuration: const Duration(milliseconds: 180),
          transitionsBuilder: (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      ),
    ],
  );
});
