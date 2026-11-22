import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../models/confirmed_order.dart' show activePurchasePlanId;
import '../../../models/plan_item.dart';
import '../../../models/xb_domain_error.dart';
import '../../../models/xb_domain_subscription.dart';
import '../../../models/xb_domain_types.dart';
import '../../../models/xb_result.dart';
import '../../../pages/plan_detail_page.dart';
import '../../../providers/auth_state_provider.dart';
import '../../../providers/user_profile_provider.dart';
import '../../../providers/xboard_providers.dart';
import '../../../sdk/guest_catalog.dart' show XboardGuestCatalogControl;
import '../../../util/period_label.dart';
import '../../../widgets/xb_async_view.dart';
import '../../../widgets/xb_components.dart';
import '../../../widgets/xb_emoji_text.dart';
import '../../../widgets/xb_feedback.dart' show xbBrandColor;
import '../../../widgets/xb_plan_details.dart';
import '../../../widgets/xb_purchase_confirmation.dart';
import '../../../widgets/xb_theme.dart';
import '../../../widgets/xb_ui_kit.dart' show XbGradientAction;
import '../../widgets/xb_content_header.dart';
import 'xb_shop_navigation.dart';

// The authenticated panel endpoint returns plans available to this account.
// A different login must start a new read, not reuse a previous account's list.
final _catalogProvider = FutureProvider.autoDispose.family<List<PlanItem>, int>(
  (ref, _) async {
    final result = await ref.watch(xboardServiceProvider).getPlans();
    return switch (result) {
      XbSuccess(:final data) => data,
      XbFailure(:final error) => throw error,
    };
  },
  retry: noAutomaticAccountRetry,
);

final _guestCatalogProvider = FutureProvider.autoDispose<List<PlanItem>>((
  ref,
) async {
  // A brand endpoint switch invalidates the prior anonymous response.
  ref.watch(apiEndpointProvider);
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
  int? _chosenPlanId;
  XbShopIntent? _scheduled;
  XbShopIntent? _handled;
  (AuthState, int)? _owner;
  bool _openingCheckout = false;
  DialogRoute<bool>? _confirmation;

  @override
  void dispose() {
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
    _chosenPlanId = null;
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
    if (!widget.active ||
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
          !widget.active ||
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
          !latestCatalog.isLoading &&
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
      setState(() => _chosenPlanId = plan.id);
      // Opening checkout is read-only; only the checkout's submit can write.
      await xbPush(
        context,
        PlanDetailPage(
          plan: plan,
          renew: renew,
          initialPeriod: renew ? null : period, // 续费由结算页默认年付；购买保留所选周期。
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
    _observeOwner(auth, revision);

    Widget body;
    if (auth == AuthState.authenticating || !ref.watch(bootstrapReadyProvider)) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final provider = authenticated
          ? _catalogProvider(revision)
          : _guestCatalogProvider;
      final catalog = ref.watch(provider);
      final profile = authenticated ? ref.watch(userProfileProvider) : null;
      body = XbAsyncView(
        // Do not animate an outgoing account's catalog into the next state.
        key: ValueKey((auth, revision, catalog.isLoading, catalog.hasError)),
        loading: catalog.isLoading,
        error: catalog.asError?.error,
        errorFallback: '加载套餐失败',
        onRetry: () => ref.invalidate(provider),
        builder: (_) {
          final offers = <_PlanOffer>[];
          final ids = <int>{};
          for (final plan in catalog.requireValue) {
            final offer = _PlanOffer.from(plan);
            if (offer != null && ids.add(plan.id)) offers.add(offer);
          }
          final sub = profile == null || profile.isLoading || profile.hasError
              ? null
              : profile.asData?.value;
          final intent = widget.intent;
          _scheduleLocation(
            authenticated: authenticated,
            revision: revision,
            ready: !(intent?.waitForProfile == true &&
                profile?.isLoading == true),
            planId: !authenticated
                ? null
                : intent?.waitForProfile == true
                ? sub?.planId
                : intent?.planId,
          );
          if (offers.isEmpty) {
            return const Center(child: Text('暂无可购买套餐'));
          }
          return SizedBox.expand(child: _catalog(
            offers,
            revision: revision,
            authenticated: authenticated,
            activeId: _activeId(sub),
            ownedId: sub?.planId,
            canCheckout: !authenticated || sub != null && !_openingCheckout,
            profileFailed: profile != null &&
                profile.hasError &&
                !profile.isLoading,
          ));
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.mobile)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Text(
              '商店',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          )
        else
          const XbContentHeader(title: '商店', maxContentWidth: _maxContentWidth),
        Expanded(child: body),
      ],
    );
  }

  Widget _catalog(
    List<_PlanOffer> offers, {
    required int revision,
    required bool authenticated,
    required int? activeId,
    required int? ownedId,
    required bool canCheckout,
    required bool profileFailed,
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
        return SingleChildScrollView(
          key: ValueKey(('shop-catalog', revision)),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(padding, 12, padding, 24),
          child: Center(
            child: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (profileFailed) ...[
                    XbErrorRetry(
                      message: '无法读取当前套餐，请重试后继续',
                      onRetry: () => ref.invalidate(userProfileProvider),
                    ),
                    const SizedBox(height: gap),
                  ],
                  Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
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
    final selected = offer.prices.firstWhere(
      (p) => p.period == _selectedPeriods[id],
      orElse: () => offer.prices.first,
    );
    return _PlanCard(
      offer: offer,
      titleKey: _titleKeys.putIfAbsent(id, () => GlobalKey()),
      selected: selected,
      renew: id == activeId,
      blocked: blocked,
      chosen: id == _chosenPlanId && !blocked,
      onSelectPeriod: (period) => setState(() {
        _selectedPeriods[id] = period;
        if (_chosenPlanId == id) _chosenPlanId = null;
      }),
      onCheckout: blocked || !canCheckout
          ? null
          : authenticated
          ? (period) => _openCheckout(offer.plan, period, revision)
          : (_) {
              if (widget.active &&
                  ref.read(authStateProvider) == AuthState.unauthenticated) {
                setState(() => _chosenPlanId = _chosenPlanId == id ? null : id);
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
      final centValue = price.amountYuan * 100;
      if (price.period == XbPlanPeriod.resetTraffic ||
          !centValue.isFinite ||
          centValue.round() <= 0 ||
          !seen.add(price.period)) {
        continue;
      }
      prices.add((period: price.period, cents: centValue.round()));
    }
    if (prices.isEmpty) return null;
    prices.sort((a, b) => a.period.index.compareTo(b.period.index));
    return _PlanOffer(plan, prices);
  }
}

class _PlanCard extends ConsumerStatefulWidget {
  const _PlanCard({
    required this.offer,
    required this.titleKey,
    required this.selected,
    required this.renew,
    required this.blocked,
    required this.chosen,
    required this.onSelectPeriod,
    required this.onCheckout,
  });

  final _PlanOffer offer;
  final GlobalKey titleKey;
  final _ShopPrice selected;
  final bool renew;
  final bool blocked;
  final bool chosen;
  final ValueChanged<XbPlanPeriod> onSelectPeriod;
  final ValueChanged<XbPlanPeriod>? onCheckout;

  @override
  ConsumerState<_PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends ConsumerState<_PlanCard> {
  late _ShopPrice _selected = widget.selected;

  @override
  void didUpdateWidget(_PlanCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selected = widget.selected;
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.offer.plan;
    final selected = _selected;
    final t = XbTokens.of(context);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    Color tone(XbPlanPeriod period) => switch (period) {
      XbPlanPeriod.monthly => dark ? const Color(0xFFF4A49A) : const Color(0xFFA82F24),
      XbPlanPeriod.quarterly => dark ? const Color(0xFFE9BC7A) : const Color(0xFF805318),
      XbPlanPeriod.yearly => dark ? const Color(0xFF9BBDED) : const Color(0xFF255B9B),
      _ => dark ? const Color(0xFFA8C1B7) : const Color(0xFF4C665E),
    };
    const mistBlue = Color(0xFF365A73);
    final buttonInk = dark ? Color.lerp(mistBlue, Colors.white, .42)! : mistBlue;
    final outline = Color.lerp(t.sf2, buttonInk, .42)!;
    final buyLabel = XbEmojiText(widget.blocked ? '当前套餐不可续费' : '${widget.renew ? '续费' : '购买'} ${plan.name}');
    final buy = widget.onCheckout == null ? null : () => widget.onCheckout!(_selected.period);
    final whole = selected.cents ~/ 100;
    final fraction = (selected.cents % 100).toString().padLeft(2, '0');
    final unit = selected.period == XbPlanPeriod.onetime
        ? planPeriodLabel(selected.period)
        : '/ ${planPeriodUnit(selected.period)}';
    return XbCard(
      radius: XbTokens.rLg,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Focus(
            key: ValueKey('shop-plan-title-${plan.id}'),
            skipTraversal: true,
            child: Builder(
              key: widget.titleKey,
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
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
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
                for (final price in widget.offer.prices)
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
                        onPressed: () {
                          if (price == _selected) return;
                          widget.onSelectPeriod(price.period);
                          setState(() => _selected = price);
                        },
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
                  fontSize: 32,
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
          if (widget.chosen)
            XbGradientAction(height: 44, onPressed: buy, child: buyLabel)
          else OutlinedButton(
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
