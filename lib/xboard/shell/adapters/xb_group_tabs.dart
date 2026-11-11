import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_clash/ui/icons/icons.dart' show AppGlyphs, GlyphIcon;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'package:prism_ui/prism_ui.dart' as prism;

import 'xb_nodes_adapter.dart' show XbGroupSummary;

/// Uses the pinned upstream Prism popup, press surfaces and page transition.
/// The strip's measurements/reveal follow v0.9.3 views/proxies/group_tabs.dart;
/// ownership guards remain local so no upstream popup/source patch is needed.
class XbGroupTabs extends StatelessWidget {
  const XbGroupTabs({
    super.key,
    required this.groups,
    required this.selected,
    required this.onSelected,
    required this.groupBuilder,
    this.targetNonce = 0,
    this.header,
  });

  final List<XbGroupSummary> groups;
  final String selected;
  final ValueChanged<String> onSelected;
  final Widget Function(BuildContext context, XbGroupSummary group)
  groupBuilder;
  final int targetNonce;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) return const SizedBox.shrink();
    final brand = material.Theme.of(context);
    final native = prism.Theme.of(context);
    final colors = brand.colorScheme;
    return prism.Theme(
      data: native.copyWith(
        platform: brand.platform,
        fontFamily: brand.textTheme.bodyMedium?.fontFamily,
        fontFamilyFallback: brand.textTheme.bodyMedium?.fontFamilyFallback,
        colorScheme: native.colorScheme.copyWith(
          brightness: colors.brightness,
          primary: colors.primary,
          onPrimary: colors.onPrimary,
          surface: colors.surface,
          onSurface: colors.onSurface,
          onSurfaceVariant: colors.onSurfaceVariant,
          surfaceContainer: colors.surfaceContainer,
          surfaceContainerLow: colors.surfaceContainerLow,
          surfaceContainerHigh: colors.surfaceContainerHigh,
          surfaceContainerHighest: colors.surfaceContainerHighest,
          outline: colors.outline,
          outlineVariant: colors.outlineVariant,
        ),
      ),
      child: _GroupPager(
        // Names/order changes retire the whole local menu owner and controller.
        // A menu opened against an old list cannot choose a different new group.
        key: ValueKey(jsonEncode(groups.map((group) => group.name).toList())),
        groups: groups,
        selected: selected,
        onSelected: onSelected,
        groupBuilder: groupBuilder,
        targetNonce: targetNonce,
        header: header,
      ),
    );
  }
}

class _GroupPager extends StatefulWidget {
  const _GroupPager({
    super.key,
    required this.groups,
    required this.selected,
    required this.onSelected,
    required this.groupBuilder,
    required this.targetNonce,
    required this.header,
  });

  final List<XbGroupSummary> groups;
  final String selected;
  final ValueChanged<String> onSelected;
  final Widget Function(BuildContext, XbGroupSummary) groupBuilder;
  final int targetNonce;
  final Widget? header;

  @override
  State<_GroupPager> createState() => _GroupPagerState();
}

class _GroupPagerState extends State<_GroupPager>
    with SingleTickerProviderStateMixin {
  final _navigator = GlobalKey<NavigatorState>();
  final _menuOpen = ValueNotifier(false);
  late final _GroupMenuObserver _menuObserver;
  bool _disposing = false;
  late final _OwnedTabController _controller;
  late String _reported;
  bool _syncing = false;
  int _generation = 0;

  int get _selectedIndex {
    final index = widget.groups.indexWhere(
      (group) => group.name == widget.selected,
    );
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    _menuObserver = _GroupMenuObserver((open) {
      if (!_disposing && mounted) _menuOpen.value = open;
    });
    _reported = widget.groups[_selectedIndex].name;
    _controller = _OwnedTabController(
      initialIndex: _selectedIndex,
      length: widget.groups.length,
      vsync: this,
    )..addListener(_selectionChanged);
  }

  void _selectionChanged() {
    if (!mounted || _syncing) return;
    final name = widget.groups[_controller.index].name;
    if (name == _reported) return;
    _reported = name;
    final generation = ++_generation;
    // Like upstream ProxiesTabView, publish outside layout/scroll notification
    // dispatch. A newer swipe/target or retired owner invalidates this report.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          generation == _generation &&
          widget.groups[_controller.index].name == name) {
        widget.onSelected(name);
      }
    });
  }

  @override
  void didUpdateWidget(_GroupPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected == widget.selected &&
        oldWidget.targetNonce == widget.targetNonce) {
      return;
    }
    final generation = ++_generation;
    final index = _selectedIndex;
    _reported = widget.groups[index].name;
    final externalTarget =
        oldWidget.targetNonce != widget.targetNonce ||
        _controller.index != index;
    if (_controller.index != index) {
      _syncing = true;
      _controller.animateTo(index);
      _syncing = false;
    }
    // External navigation (e.g. the home line card) invalidates an open menu's
    // checked snapshot. Close only this local navigator's popup, after build.
    if (externalTarget && (_navigator.currentState?.canPop() ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _generation) {
          _navigator.currentState?.popUntil((route) => route.isFirst);
        }
      });
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _generation++;
    _controller.removeListener(_selectionChanged);
    _controller.dispose();
    _menuOpen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: _menuOpen,
    builder: (context, open, child) => TapRegion(
      enabled: open,
      consumeOutsideTaps: true,
      onTapOutside: (_) {
        final navigator = _navigator.currentState;
        if (navigator != null && navigator.canPop()) navigator.pop();
      },
      child: child!,
    ),
    child: NavigatorPopHandler<void>(
      onPopWithResult: (_) => _navigator.currentState?.pop(),
      child: Navigator(
        key: _navigator,
        observers: [_menuObserver],
        pages: [
          _GroupRootPage(
            key: const ValueKey('brand-group-pager'),
            child: Column(
              children: [
                if (widget.header != null) widget.header!,
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _GroupStrip(
                    controller: _controller,
                    names: [for (final group in widget.groups) group.name],
                  ),
                ),
                Expanded(
                  child: prism.TabBarView(
                    controller: _controller,
                    children: [
                      for (final group in widget.groups)
                        KeyedSubtree(
                          key: ValueKey(group.name),
                          child: Builder(
                            builder: (context) =>
                                widget.groupBuilder(context, group),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        onDidRemovePage: (_) {},
      ),
    ),
  );
}

class _GroupMenuObserver extends NavigatorObserver {
  _GroupMenuObserver(this.onChanged);
  final ValueChanged<bool> onChanged;
  final _menus = <Route<dynamic>>{};

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings is! Page) {
      _menus.add(route);
      onChanged(true);
    }
  }

  void _retire(Route<dynamic> route) {
    if (!_menus.contains(route)) return;
    void finish() {
      _menus.remove(route);
      onChanged(_menus.isNotEmpty);
    }

    if (route is TransitionRoute<dynamic>) {
      // Keep outside taps consumed until the returning popup has landed.
      unawaited(route.completed.whenComplete(finish));
    } else {
      finish();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _retire(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _retire(route);
}

/// The local navigator owns popups, not the shell's content page. A repeated
/// menu action before repaint must not consume the page under the popup.
class _GroupRootPage extends Page<void> {
  const _GroupRootPage({super.key, required this.child});
  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) => _GroupRootRoute<void>(this);
}

class _GroupRootRoute<T> extends PageRoute<T> {
  _GroupRootRoute(_GroupRootPage page) : super(settings: page);

  @override
  Duration get transitionDuration => Duration.zero;
  @override
  bool get maintainState => true;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool didPop(T? result) {
    // Navigator marks an entry "popping" before calling didPop; isFirst can
    // already be false then. Identify our content page by its stable settings.
    if (settings is _GroupRootPage) return false;
    return super.didPop(result);
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => (settings as _GroupRootPage).child;
}

/// Upstream popup selection is deferred until its closing animation finishes.
/// A retired owner must ignore that callback rather than animate a dead ticker.
class _OwnedTabController extends prism.TabController {
  _OwnedTabController({
    required super.initialIndex,
    required super.length,
    required super.vsync,
  });

  bool _disposed = false;

  @override
  void animateTo(int value, {Duration? duration, Curve curve = Curves.ease}) {
    if (_disposed || value < 0 || value >= length) return;
    super.animateTo(value, duration: duration, curve: curve);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Label-only adaptation of the upstream GroupTabs strip. All menu rendering,
/// opening/return springs, selection checkmarks and press tracking are Prism's.
class _GroupStrip extends StatefulWidget {
  const _GroupStrip({required this.controller, required this.names});
  final prism.TabController controller;
  final List<String> names;

  @override
  State<_GroupStrip> createState() => _GroupStripState();
}

class _GroupStripState extends State<_GroupStrip> {
  final _scroll = ScrollController();
  final _hasMore = ValueNotifier(false);
  final _fade = ValueNotifier(0.0);
  late final _selected = ValueNotifier(widget.controller.index);
  _GroupExtents? _extents;

  @override
  void initState() {
    super.initState();
    widget.controller.animation!.addListener(_followSelection);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(jump: true));
  }

  @override
  void dispose() {
    widget.controller.animation?.removeListener(_followSelection);
    _scroll.dispose();
    _hasMore.dispose();
    _fade.dispose();
    _selected.dispose();
    super.dispose();
  }

  void _followSelection() {
    final controller = widget.controller;
    final index = controller.indexIsChanging
        ? controller.index
        : controller.animation!.value.round();
    if (_selected.value == index) return;
    _selected.value = index;
    _reveal();
  }

  void _reveal({bool jump = false}) {
    final extents = _extents;
    if (!mounted || extents == null || !_scroll.hasClients) return;
    final position = _scroll.position;
    final index = _selected.value;
    if (!position.hasContentDimensions ||
        index < 0 ||
        index >= extents.widths.length) {
      return;
    }
    final center = 16 + extents.starts[index] + extents.widths[index] / 2;
    final offset = (center - position.viewportDimension / 2).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (jump) {
      position.jumpTo(offset);
    } else {
      unawaited(
        position.animateTo(
          offset,
          duration: prism.commonDuration,
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  bool _metrics(ScrollMetrics metrics) {
    _fade.value = (metrics.extentAfter / 24).clamp(0.0, 1.0);
    final more = metrics.maxScrollExtent > 0;
    if (_hasMore.value != more) {
      _hasMore.value = more;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(jump: true));
    }
    return false;
  }

  void _select(int index) {
    // PopupMenu invokes this only after the return animation. The strip may
    // already have been retired by a new group list, mode or account.
    if (!mounted || index < 0 || index >= widget.names.length) return;
    widget.controller.animateTo(index);
  }

  Widget _moreButton() => prism.TonalButtonTheme(
    size: prism.TonalButtonSize.section,
    child: prism.ElasticPress(
      child: prism.PopupAnchor(
        targetBuilder: (open) => prism.IconButton(
          tooltip: '线路分组',
          onPressed: open,
          icon: const GlyphIcon(AppGlyphs.chevronDown),
        ),
        popupBuilder: (_) => prism.PopupMenu(
          maxVisibleItems: 7,
          items: [
            for (final (index, name) in widget.names.indexed)
              prism.PopupMenuItem(
                label: name,
                checked: index == widget.controller.index,
                onPressed: () => _select(index),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _strip(_GroupExtents extents, bool more) => ListView.custom(
    controller: _scroll,
    scrollDirection: Axis.horizontal,
    padding: EdgeInsetsDirectional.only(start: 16, end: more ? 0 : 16),
    itemExtentBuilder: (index, _) => index < extents.widths.length
        ? extents.widths[index] + (index < widget.names.length - 1 ? 8 : 0)
        : null,
    childrenDelegate: _GroupTabsDelegate(
      (_, index) => Padding(
        padding: EdgeInsetsDirectional.only(
          end: index < widget.names.length - 1 ? 8 : 0,
        ),
        child: ValueListenableBuilder<int>(
          valueListenable: _selected,
          builder: (context, selected, _) {
            final on = selected == index;
            final colors = prism.Theme.of(context).colorScheme;
            return prism.Card(
              isSelected: on,
              fillsSelection: true,
              shape: prism.AppShape.full,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              onPressed: () => _select(index),
              child: AnimatedDefaultTextStyle(
                duration: prism.midDuration,
                style: prism.AppTextStyle.subheadline
                    .of(context, emphasized: true)
                    .copyWith(
                      color: on ? colors.onPrimary : colors.onSurfaceVariant,
                    ),
                child: prism.EmojiText(widget.names[index], maxLines: 1),
              ),
            );
          },
        ),
      ),
      childCount: widget.names.length,
      extent: extents.total,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final extents = _extents = _GroupExtents.of(
      context,
      widget.names,
      _extents,
    );
    return SizedBox(
      height: prism.TonalButtonSize.section.button,
      child: ValueListenableBuilder<bool>(
        valueListenable: _hasMore,
        child: _moreButton(),
        builder: (context, more, button) => Row(
          children: [
            Expanded(
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (event) => _metrics(event.metrics),
                child: NotificationListener<ScrollUpdateNotification>(
                  onNotification: (event) => _metrics(event.metrics),
                  child: ValueListenableBuilder<double>(
                    valueListenable: _fade,
                    child: _strip(extents, more),
                    builder: (context, fade, child) => ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (bounds) =>
                          LinearGradient(
                            begin: AlignmentDirectional.centerStart,
                            end: AlignmentDirectional.centerEnd,
                            colors: [
                              const Color(0xff000000),
                              Color.fromRGBO(0, 0, 0, 1 - fade),
                            ],
                            stops: [math.max(0.0, 1 - 24 / bounds.width), 1],
                          ).createShader(
                            bounds,
                            textDirection: Directionality.of(context),
                          ),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
            if (more)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 8, end: 16),
                child: button,
              ),
          ],
        ),
      ),
    );
  }
}

class _GroupExtents {
  _GroupExtents(this.key, this.widths) {
    var offset = 0.0;
    for (final width in widths) {
      starts.add(offset);
      offset += width + 8;
    }
  }
  final Object key;
  final List<double> widths;
  final List<double> starts = [];
  double get total => widths.isEmpty ? 0 : starts.last + widths.last;

  static _GroupExtents of(
    BuildContext context,
    List<String> names,
    _GroupExtents? previous,
  ) {
    final style = prism.AppTextStyle.subheadline.of(context, emphasized: true);
    final minimum = prism.Card.minimumOf(context).minWidth;
    final padding = prism.Card.paddingOf(
      context,
      const EdgeInsets.symmetric(horizontal: 16),
    ).horizontal;
    final key = (
      jsonEncode(names),
      style,
      MediaQuery.boldTextOf(context),
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
      Localizations.maybeLocaleOf(context),
      minimum,
      padding,
    );
    if (previous != null && previous.key == key) return previous;
    return _GroupExtents(key, [
      for (final name in names)
        math.max(
          minimum,
          prism.EmojiText.widthOf(context, name, style).ceilToDouble() +
              padding,
        ),
    ]);
  }
}

class _GroupTabsDelegate extends SliverChildBuilderDelegate {
  _GroupTabsDelegate(
    super.builder, {
    required super.childCount,
    required this.extent,
  }) : super(addAutomaticKeepAlives: false);
  final double extent;

  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => extent;
}
