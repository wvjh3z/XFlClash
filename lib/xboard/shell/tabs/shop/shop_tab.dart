import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../models/confirmed_order.dart' show activePurchasePlanId, orderQuoteCents;
import '../../../models/plan_item.dart';
import '../../../models/xb_domain_error.dart';
import '../../../models/xb_domain_subscription.dart';
import '../../../models/xb_domain_types.dart';
import '../../../models/xb_result.dart';
import '../../../pages/plan_detail_page.dart';
import '../../../pages/commerce_read_recovery.dart';
import '../../../providers/auth_state_provider.dart';
import '../../../providers/catalog_read_cache.dart';
import '../../../providers/display_snapshot.dart';
import '../../../providers/user_profile_provider.dart';
import '../../../providers/xboard_providers.dart';
import '../../../sdk/guest_catalog.dart' show XboardGuestCatalogControl;
import '../../../util/period_label.dart';
import '../../../widgets/xb_plan_notice_card.dart';
import '../../../widgets/xb_network_read_recovery.dart';
import '../../../providers/xboard_connectivity_provider.dart';
import '../../../widgets/xb_components.dart';
import '../../../widgets/xb_emoji_text.dart';
import '../../../widgets/xb_feedback.dart' show xbBrandColor;
import '../../../widgets/xb_plan_details.dart';
import '../../../widgets/xb_purchase_confirmation.dart';
import '../../../widgets/xb_theme.dart';
import 'xb_shop_navigation.dart';

// The authenticated panel endpoint returns plans available to this account.
// A different login must start a new read, not reuse a previous account's list.
final _catalogProvider = FutureProvider.autoDispose.family<List<PlanItem>, int>(
  (ref, revision) async {
    final cache = ref.watch(shopReadCacheProvider);
    final key = ('shop', revision);
    return readDisplaySnapshot(ref, cache, key, 'plans', planSnapshots, () async {
      if (ref.read(isOfflineProvider) || ref.read(interfaceUnavailableProvider)) {
        throw const XbNetwork(XbNetworkKind.connectionFailed, '当前离线');
      }
      final result = await ref.watch(xboardServiceProvider).getPlans();
      return switch (result) {
        XbSuccess(:final data) => data,
        XbFailure(:final error) => throw error,
      };
    });
  },
  retry: noAutomaticAccountRetry,
);

// Identity only: unavailable SDK/service errors belong in the catalog's
// AsyncValue, not in the shop's widget build.
final _catalogOwnerProvider = Provider.autoDispose<Object?>((ref) {
  try { return ref.watch(xboardServiceProvider); } catch (_) { return null; }
});

final _guestCatalogProvider = FutureProvider.autoDispose<List<PlanItem>>((
  ref,
) async {
  // A brand endpoint switch invalidates the prior anonymous response.
  final cache = ref.watch(shopReadCacheProvider);
  const key = 'guest-shop';
  return readDisplaySnapshot(ref, cache, key, 'plans', planSnapshots, () async {
    if (ref.read(isOfflineProvider) || ref.read(interfaceUnavailableProvider)) {
      throw const XbNetwork(XbNetworkKind.connectionFailed, '当前离线');
    }
    final service = ref.watch(xboardServiceProvider);
    final result = service is XboardGuestCatalogControl
        ? await (service as XboardGuestCatalogControl).getGuestCatalog()
        : const XbFailure<List<PlanItem>>(
            XbUnexpected('guestCatalog', '公开套餐暂不可用'),
          );
    return switch (result) {
      XbSuccess(:final data) => data,
      XbFailure(:final error) => throw error,
    };
  });
}, retry: noAutomaticAccountRetry);

class ShopTab extends ConsumerStatefulWidget {
  const ShopTab({
    super.key,
    required this.active,
    required this.mobile,
    required this.onTapLogin,
    this.intent,
    this.onIntentHandled,
  });

  final bool active;
  final bool mobile;
  final VoidCallback onTapLogin;
  final XbShopIntent? intent;
  final ValueChanged<XbShopIntent>? onIntentHandled;

  @override
  ConsumerState<ShopTab> createState() => _ShopTabState();
}

class _ShopTabState extends ConsumerState<ShopTab> {
  static const _maxContentWidth = 1000.0;
  static const _columnBreakpoint = 700.0;

  final _scroll = ScrollController(keepScrollOffset: false);
  final _titleKeys = <int, GlobalKey>{};
  final _selectedPeriods = <int, XbPlanPeriod>{};
  XbShopIntent? _scheduled;
  XbShopIntent? _handled;
  (AuthState, int)? _owner;
  bool _openingCheckout = false;
  Object? _manualRefreshOwner;
  Object? _catalogOwner;
  List<PlanItem>? _lastCatalog;
  XbDomainSubscription? _lastProfile;
  DialogRoute<bool>? _confirmation;

  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refreshExpired);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshExpired());
  }

  @override
  void didUpdateWidget(covariant ShopTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshExpired());
    }
  }

  void _refreshExpired() {
    if (!mounted || !widget.active || !ref.read(bootstrapReadyProvider) ||
        ref.read(isOfflineProvider) || ref.read(interfaceUnavailableProvider)) {
      return;
    }
    final auth = ref.read(authStateProvider);
    if (auth == AuthState.authenticating) return;
    final revision = ref.read(authStateProvider.notifier).sessionRevision;
    final user = auth == AuthState.authenticated;
    final provider = user ? _catalogProvider(revision) : _guestCatalogProvider;
    if (ref.read(provider) is AsyncData<List<PlanItem>> &&
        !ref.read(shopReadCacheProvider).fresh(user ? ('shop', revision) : 'guest-shop')) {
      ref.invalidate(provider);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _scroll.dispose();
    super.dispose();
  }

  static int? _activeId(XbDomainSubscription? profile) =>
      activePurchasePlanId(profile?.planId, profile?.expiredAt);

  void _observeOwner(AuthState auth, int revision) {
    final next = (auth, revision);
    if (_owner == next) return;
    _owner = next;
    _selectedPeriods.clear();
    _titleKeys.clear();
    final dialog = _confirmation;
    if (dialog != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (dialog.isActive) dialog.navigator?.removeRoute(dialog);
      });
    }
  }

  void _scheduleLocation({
    required bool authenticated,
    required int revision,
    required bool ready,
    required int? planId,
  }) {
    final intent = widget.intent;
    if (!widget.active ||
        ref.read(isOfflineProvider) ||
        !ready ||
        intent == null ||
        identical(intent, _handled) ||
        identical(intent, _scheduled)) {
      return;
    }
    _scheduled = intent;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(_scheduled, intent)) return;
      _scheduled = null;
      if (!mounted || !widget.active || !identical(widget.intent, intent)) {
        return;
      }
      final stillAuthenticated =
          ref.read(authStateProvider) == AuthState.authenticated;
      final stillRevision = ref.read(authStateProvider.notifier).sessionRevision;
      if (stillAuthenticated != authenticated || stillRevision != revision) {
        return;
      }
      // Discard stale account intents; the new session starts at the top.
      if (intent.revision == revision &&
          intent.authenticated == authenticated &&
          _scroll.hasClients) {
        final title = _titleKeys[planId]?.currentContext;
        final render = title?.findRenderObject();
        if (title != null && render != null && render.attached) {
          _scroll.position.ensureVisible(render, alignment: 0.08);
          Focus.of(title).requestFocus();
        } else {
          _scroll.jumpTo(_scroll.position.minScrollExtent);
          final focused = FocusManager.instance.primaryFocus;
          if (focused != null && _titleKeys.values.any((key) {
            final context = key.currentContext;
            return context != null && Focus.maybeOf(context) == focused;
          })) {
            focused.unfocus();
          }
        }
      }
      _handled = intent;
      widget.onIntentHandled?.call(intent);
    });
  }

  Future<void> _openCheckout(
    PlanItem plan,
    XbPlanPeriod period,
    int revision,
  ) async {
    if (!widget.active || ref.read(isOfflineProvider) || ref.read(interfaceUnavailableProvider) ||
        _openingCheckout ||
        ref.read(authStateProvider) != AuthState.authenticated ||
        ref.read(authStateProvider.notifier).sessionRevision != revision) {
      return;
    }
    final profile = ref.read(userProfileProvider);
    if (profile.isLoading || !profile.hasValue || profile.hasError) return;
    final service = ref.read(xboardServiceProvider);
    final activeId = _activeId(profile.asData?.value);
    if (profile.asData?.value.planId == plan.id && !plan.renewable) return;
    final renew = activeId == plan.id;
    final catalog = _catalogProvider(revision);

    bool current() {
      if (!mounted ||
          !widget.active || ref.read(isOfflineProvider) || ref.read(interfaceUnavailableProvider) ||
          ref.read(authStateProvider) != AuthState.authenticated ||
          ref.read(authStateProvider.notifier).sessionRevision != revision ||
          !identical(ref.read(xboardServiceProvider), service)) {
        return false;
      }
      final latestProfile = ref.read(userProfileProvider);
      final latestCatalog = ref.read(catalog);
      return !latestProfile.isLoading &&
          latestProfile.hasValue &&
          !latestProfile.hasError &&
          _activeId(latestProfile.asData?.value) == activeId &&
          !latestCatalog.isLoading && !latestCatalog.hasError &&
          (latestCatalog.asData?.value.contains(plan) ?? false) &&
          (ModalRoute.of(context)?.isCurrent ?? true);
    }

    if (!current()) return;
    setState(() => _openingCheckout = true);
    try {
      if (activeId != null) {
        final route = xbDialogRoute<bool>(
          context: context,
          brandColor: xbBrandColor(),
          builder: (_) => XbPlanConfirmation(
            planName: profile.asData?.value.planName ?? '当前套餐',
            targetName: renew ? null : plan.name,
            confirmLabel: renew ? '继续续费' : '确认更换',
          ),
        );
        _confirmation = route;
        final accepted = await Navigator.of(
          context,
          rootNavigator: true,
        ).push(route);
        _confirmation = null;
        if (accepted != true || !current()) return;
      }
      if (!mounted) return;
      // Opening checkout is read-only; only the checkout's submit can write.
      await xbPush(
        context,
        PlanDetailPage(
          plan: plan,
          renew: renew,
          initialPeriod: period,
          confirmedFor: activeId,
        ),
        brandColor: xbBrandColor(),
      );
    } finally {
      if (mounted) setState(() => _openingCheckout = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authStateProvider);
    final revision = ref.read(authStateProvider.notifier).sessionRevision;
    final authenticated = auth == AuthState.authenticated;
    final offline = ref.watch(isOfflineProvider) || ref.watch(interfaceUnavailableProvider);
    final ready = ref.watch(bootstrapReadyProvider);
    final source = (auth, revision, ready && auth != AuthState.authenticating ? ref.watch(_catalogOwnerProvider) : null,
        ref.watch(shopPanelScopeProvider));
    if (_catalogOwner != source) {
      _lastCatalog = null;
      _lastProfile = null;
      _catalogOwner = source;
    }
    _observeOwner(auth, revision);

    Widget catalogPlaceholder() => Semantics(
      label: '正在加载套餐',
      child: _catalog(const [], revision: revision, authenticated: authenticated,
          activeId: null, ownedId: null, canCheckout: false, header: null, loading: true),
    );
    Widget body;
    if (auth == AuthState.authenticating || !ready) {
      body = catalogPlaceholder();
    } else {
      final provider = authenticated
          ? _catalogProvider(revision)
          : _guestCatalogProvider;
      final catalog = ref.watch(provider);
      final profile = authenticated ? ref.watch(userProfileProvider) : null;
      if (!catalog.isLoading && !catalog.hasError) _lastCatalog = catalog.asData?.value;
      if (profile != null && !profile.isLoading && !profile.hasError) _lastProfile = profile.asData?.value;
      if (catalog.hasError && !xbIsRecoverableReadError(catalog.error)) _lastCatalog = null;
      if (profile?.hasError == true && !xbIsRecoverableReadError(profile?.error)) _lastProfile = null;
      final visibleCatalog = _lastCatalog;
      final stale = offline || catalog.isLoading || catalog.hasError;
      final pricesFailed = !catalog.isLoading && catalog.hasError;
      final profileFailed = profile != null && !profile.isLoading && profile.hasError;
      final waiting = catalog.isLoading || profile?.isLoading == true;
      final failedSource = pricesFailed && profileFailed ? '价格和套餐资料' : pricesFailed ? '价格' : '套餐资料';
      void refreshFailed() {
        if (!widget.active || _catalogOwner != source || ref.read(isOfflineProvider) ||
            ref.read(interfaceUnavailableProvider) || ref.read(authStateProvider.notifier).sessionRevision != revision ||
            _manualRefreshOwner == source) {
          return;
        }
        final prices = ref.read(provider);
        final account = authenticated ? ref.read(userProfileProvider) : null;
        final refreshPrices = prices.hasError && !prices.isLoading;
        final refreshProfile = account != null && account.hasError && !account.isLoading;
        if (!refreshPrices && !refreshProfile) return;
        setState(() => _manualRefreshOwner = source);
        Future.wait<dynamic>([
          if (refreshPrices) ref.refresh(provider.future),
          if (refreshProfile) ref.refresh(userProfileProvider.future),
        ]).then<void>((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(() {
          if (mounted && _manualRefreshOwner == source) setState(() => _manualRefreshOwner = null);
        });
      }
      xbListenForReadRecovery(context, ref, () {
        bool current() => widget.active && _catalogOwner == source &&
            _manualRefreshOwner != source &&
            !ref.read(interfaceUnavailableProvider) && !ref.read(isOfflineProvider) &&
            ref.read(authStateProvider.notifier).sessionRevision == revision;
        if (!current()) return;
        final latest = ref.read(provider);
        recoverCommerceRead(context: context, current: current,
          pending: latest.isLoading ? ref.read(provider.future) : null,
          retryIfFailed: () async {
            final state = ref.read(provider);
            if (!state.isLoading && xbIsRecoverableReadError(state.error)) ref.invalidate(provider);
          });
        if (authenticated) {
          final account = ref.read(userProfileProvider);
          if (!account.isLoading && xbIsRecoverableReadError(account.error)) ref.invalidate(userProfileProvider);
        }
      }, active: widget.active);
      body = Builder(builder: (_) {
          final offers = <_PlanOffer>[];
          final ids = <int>{};
          for (final plan in visibleCatalog ?? const <PlanItem>[]) {
            final offer = _PlanOffer.from(plan);
            if (offer != null && ids.add(plan.id)) offers.add(offer);
          }
          final sub = profile == null || profile.isLoading || profile.hasError
              ? _lastProfile
              : profile.asData?.value;
          final intent = widget.intent;
          _scheduleLocation(
            authenticated: authenticated,
            revision: revision,
            ready: visibleCatalog != null && !catalog.isLoading && !catalog.hasError && !(intent?.waitForProfile == true &&
                profile?.isLoading == true),
            planId: !authenticated
                ? null
                : intent?.waitForProfile == true
                ? sub?.planId
                : intent?.planId,
          );
          if (offers.isEmpty && !waiting && !offline && !pricesFailed && !profileFailed) {
            return const Center(child: Text('暂无可购买套餐'));
          }
          final manualRefresh = _manualRefreshOwner == source;
          final showNotice = manualRefresh || pricesFailed || profileFailed || offline && !waiting;
          if (waiting && !showNotice && offers.isEmpty) return catalogPlaceholder();
          final previous = visibleCatalog == null || !stale ? '' :
              offers.isEmpty ? '上次目录没有可购买套餐。' : '当前显示上次价格。';
          return SizedBox.expand(child: _catalog(
            offers,
            revision: revision,
            authenticated: authenticated,
            activeId: _activeId(sub),
            ownedId: sub?.planId,
            canCheckout: !stale && (!authenticated || sub != null && profile?.isLoading == false && profile?.hasError == false && !_openingCheckout),
            onRefresh: () async {
              if (offline || ref.read(provider).isLoading) return;
              ref.invalidate(provider);
              try { await ref.read(provider.future); } catch (_) { /* Render the provider error. */ }
            },
            header: showNotice ? XbPlanNoticeCard(
              title: manualRefresh ? '正在同步商店' : offline ? '商店未同步' : '$failedSource同步失败',
              desc: manualRefresh ? '同步完成后可核对最新套餐。' : offline ? '$previous请检查网络连接后刷新。' : '$previous刷新后再选购套餐。',
              urgent: false,
              icon: Icons.access_time,
              actionLabel: manualRefresh ? '正在刷新…' : '刷新',
              centered: !widget.mobile,
              onTap: manualRefresh || offline || source.$3 == null ? null : refreshFailed,
            ) : waiting ? Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator(minHeight: 2,
                  semanticsLabel: catalog.isLoading ? '正在同步套餐价格' : '正在同步套餐资料'),
            ) : null,
          ));
        },
      );
    }

    return body;
  }

  Widget _catalog(
    List<_PlanOffer> offers, {
    required int revision,
    required bool authenticated,
    required int? activeId,
    required int? ownedId,
    required bool canCheckout,
    required Widget? header,
    bool loading = false,
    RefreshCallback? onRefresh,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= _columnBreakpoint;
        const gap = 12.0;
        const padding = 16.0;
        final width = (constraints.maxWidth - 2 * padding)
            .clamp(0.0, _maxContentWidth - 2 * padding)
            .toDouble();
        final cardWidth = twoColumns ? (width - gap) / 2 : width;
        final scroll = SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          key: ValueKey(('shop-catalog', revision)),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(padding, 12, padding, 24),
          child: Center(
            child: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?header,
                  Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      if (loading)
                        for (var i = 0; i < (twoColumns ? 4 : 3); i++)
                          SizedBox(width: cardWidth, key: ValueKey('shop-placeholder-$i'),
                            child: const ExcludeSemantics(child: _CatalogSkeleton())),
                      for (final offer in offers)
                        SizedBox(
                          key: ValueKey(offer.plan.id),
                          width: cardWidth,
                          child: _planCard(
                            offer,
                            activeId,
                            blocked: ownedId == offer.plan.id && !offer.plan.renewable,
                            revision: revision,
                            authenticated: authenticated,
                            canCheckout: canCheckout,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
        return onRefresh == null ? scroll : RefreshIndicator(onRefresh: onRefresh, child: scroll);
      },
    );
  }

  Widget _planCard(
    _PlanOffer offer,
    int? activeId, {
    required bool blocked,
    required int revision,
    required bool authenticated,
    required bool canCheckout,
  }) {
    final id = offer.plan.id;
    final manual = offer.prices.where((p) => p.period == _selectedPeriods[id]).firstOrNull;
    final selected = manual ?? offer.prices.first;
    return _PlanCard(
      offer: offer,
      titleKey: _titleKeys.putIfAbsent(id, () => GlobalKey()),
      selected: selected,
      renew: id == activeId,
      blocked: blocked,
      onSelectPeriod: (period) => setState(() {
        _selectedPeriods[id] = period;
      }),
      onCheckout: blocked || !canCheckout
          ? null
          : authenticated
          ? () => _openCheckout(offer.plan, manual?.period ??
              offer.prices.where((p) => p.period == XbPlanPeriod.yearly).firstOrNull?.period ??
              selected.period, revision)
          : () {
              if (widget.active &&
                  ref.read(authStateProvider) == AuthState.unauthenticated) {
                widget.onTapLogin();
              }
            },
    );
  }
}

typedef _ShopPrice = ({XbPlanPeriod period, int cents});

class _PlanOffer {
  const _PlanOffer(this.plan, this.prices);

  final PlanItem plan;
  final List<_ShopPrice> prices;

  static _PlanOffer? from(PlanItem plan) {
    final prices = <_ShopPrice>[];
    final seen = <XbPlanPeriod>{};
    for (final price in plan.prices) {
      final cents = orderQuoteCents(price.amountYuan);
      if (price.period == XbPlanPeriod.resetTraffic ||
          cents == null || cents <= 0 ||
          !seen.add(price.period)) {
        continue;
      }
      prices.add((period: price.period, cents: cents));
    }
    if (prices.isEmpty) return null;
    prices.sort((a, b) => a.period.index.compareTo(b.period.index));
    return _PlanOffer(plan, prices);
  }
}

const _cardPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 9);

/// Catalog data is not yet known. Reserve space for a typical six-row plan;
/// once loaded, HTML descriptions still take their actual height.
class _CatalogSkeleton extends StatelessWidget {
  const _CatalogSkeleton();

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    final theme = XbTokens.of(context);
    Widget bar(double fraction, double height) => Align(alignment: Alignment.centerLeft,
        child: XbSkeletonBar(widthFactor: fraction, height: height));
    return XbCard(radius: XbTokens.rLg, padding: _cardPadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: scale.scale(26), child: bar(.36, scale.scale(17))),
        SizedBox(height: 46, child: Align(alignment: Alignment.centerLeft,
          child: FractionallySizedBox(widthFactor: .84, child: Row(children: [
            for (var i = 0; i < 6; i++) ...[
              if (i != 0) const SizedBox(width: 4),
              const Expanded(child: XbSkeletonBar(height: 21, radius: 8)),
            ],
          ])),
        )),
        SizedBox(height: scale.scale(36), child: bar(.40, scale.scale(25))),
        const SizedBox(height: 5),
        const SizedBox(height: 48, child: Center(child: XbSkeletonBar(height: 44, radius: 12))),
        const SizedBox(height: 4),
        Divider(height: 1, color: theme.hair),
        const SizedBox(height: 4),
        for (final fraction in [.43, .67, .61, .75, .88, .76])
          SizedBox(height: scale.scale(24), child: bar(fraction, scale.scale(11))),
      ]));
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.offer,
    required this.titleKey,
    required this.selected,
    required this.renew,
    required this.blocked,
    required this.onSelectPeriod,
    required this.onCheckout,
  });

  final _PlanOffer offer;
  final GlobalKey titleKey;
  final _ShopPrice selected;
  final bool renew;
  final bool blocked;
  final ValueChanged<XbPlanPeriod> onSelectPeriod;
  final VoidCallback? onCheckout;

  @override
  Widget build(BuildContext context) {
    final plan = offer.plan;
    final t = XbTokens.of(context);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    Color tone(XbPlanPeriod period) => switch (period) {
      XbPlanPeriod.monthly => dark ? const Color(0xFFF4A49A) : const Color(0xFFA82F24),
      XbPlanPeriod.quarterly => dark ? const Color(0xFFE9BC7A) : const Color(0xFF805318),
      XbPlanPeriod.halfYearly => dark ? const Color(0xFF88CFA3) : const Color(0xFF24683F),
      XbPlanPeriod.twoYearly => dark ? const Color(0xFFCEADEA) : const Color(0xFF714694),
      XbPlanPeriod.threeYearly => dark ? const Color(0xFF85D1D6) : const Color(0xFF11676E),
      XbPlanPeriod.yearly => dark ? const Color(0xFF9BBDED) : const Color(0xFF255B9B),
      _ => dark ? const Color(0xFFA8C1B7) : const Color(0xFF4C665E),
    };
    const mistBlue = Color(0xFF365A73);
    final buttonInk = dark ? Color.lerp(mistBlue, Colors.white, .42)! : mistBlue;
    final outline = Color.lerp(t.sf2, buttonInk, .42)!;
    final buyLabel = XbEmojiText(blocked ? '当前套餐不可续费' : '${renew ? '续费' : '购买'} ${plan.name}');
    final buy = onCheckout;
    final whole = selected.cents ~/ 100;
    final fraction = (selected.cents % 100).toString().padLeft(2, '0');
    final unit = selected.period == XbPlanPeriod.onetime
        ? planPeriodLabel(selected.period)
        : '/ ${planPeriodUnit(selected.period)}';
    return XbCard(
      radius: XbTokens.rLg,
      padding: _cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Focus(
            key: ValueKey('shop-plan-title-${plan.id}'),
            skipTraversal: true,
            child: Builder(
              key: titleKey,
              builder: (context) => Semantics(
                header: true,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Focus.of(context).hasFocus
                        ? theme.colorScheme.primary.withValues(alpha: 0.10)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(XbTokens.rSm),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: XbEmojiText(
                      plan.name,
                      style: xbPlanTitleStyle(theme, fontSize: 19),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            primary: false,
            child: Row(
              children: [
                for (final price in offer.prices)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 3),
                    child: Semantics(
                      key: ValueKey(('shop-period', plan.id, price.period)),
                      selected: price.period == selected.period,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 22),
                          visualDensity: const VisualDensity(horizontal: -4),
                          tapTargetSize: MaterialTapTargetSize.padded,
                          textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          foregroundColor: tone(price.period),
                          backgroundColor: tone(price.period).withValues(alpha: price.period == selected.period ? 0.14 : 0.08),
                          side: BorderSide(color: tone(price.period).withValues(alpha: price.period == selected.period ? 0.64 : 0.22)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(XbTokens.rLg),
                          ),
                        ),
                        onPressed: () => onSelectPeriod(price.period),
                        child: Text(planPeriodLabel(price.period)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Semantics(
            liveRegion: true,
            child: Text.rich(
              TextSpan(
                text: '¥$whole.$fraction',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontSize: 26,
                  height: 1.12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w700,
                  color: t.on,
                ),
                children: [
                  TextSpan(
                    text: '  $unit',
                    style: theme.textTheme.bodyMedium?.copyWith(color: t.onv),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          OutlinedButton(
            onPressed: buy,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 44),
              foregroundColor: buttonInk,
              side: BorderSide(color: outline),
            ),
            child: buyLabel,
          ),
          XbPlanDetails(plan: plan, showQuota: false, compact: true),
        ],
      ),
    );
  }
}
