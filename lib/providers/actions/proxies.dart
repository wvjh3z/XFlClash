part of '../action.dart';

class _DelayTestTarget {
  const _DelayTestTarget({
    required this.proxyName,
    required this.testUrl,
    required this.key,
  });

  final String proxyName;
  final String testUrl;
  final String key;
}

typedef _DelayTestBatch = ({List<Proxy> proxies, String? testUrl});

class _SelectionRollback {
  _SelectionRollback(this.name);

  String name;
  int confirmedOrder = -1;
  int inFlight = 0;
}

class _ProxySelectionRequest {
  _ProxySelectionRequest({
    required this.profileId,
    required this.epoch,
    required this.groupName,
    required this.proxyName,
    required this.rollback,
    required this.order,
    required this.core,
  });

  final int? profileId;
  final int epoch;
  final String groupName;
  final String proxyName;
  final _SelectionRollback rollback;
  final int order;
  final CoreController core;
  bool completed = false;
  bool rejected = false;
}

class _DelayTestJob {
  _DelayTestJob(Iterable<String> keys, this.timeout) : held = keys.toSet();

  final Set<String> held;
  final Duration timeout;
  final Set<String> startedOnDispatch = {};
  bool cancelled = false;
  final List<Delay> results = [];
}

@Riverpod(keepAlive: true)
class ProxiesAction extends _$ProxiesAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  final TaskPool _delayTestPool = TaskPool(maxConcurrentDelayTests);

  final List<_DelayTestJob> _delayTestJobs = [];

  final List<Delay> _bufferedDelays = [];

  final List<String> _bufferedStarts = [];

  final List<String> _bufferedFinishes = [];

  Timer? _delayFlushTimer;

  final Map<String, _ProxySelectionRequest> _pendingSelections = {};
  final Map<String, _ProxySelectionRequest> _latestSelections = {};
  int _selectionEpoch = 0;
  int _selectionOrder = 0;

  @override
  void build() {
    ref.onDispose(() {
      _delayFlushTimer?.cancel();
      _invalidateSelections();
    });
    ref.listen(currentProfileIdProvider, (previous, next) {
      if (previous != next) _invalidateSelections();
    });
    ref.listen(coreHandlerProvider, (previous, next) {
      if (!identical(previous, next)) _invalidateSelections();
    });
    ref.listen(coreStatusProvider, (_, next) {
      if (next != CoreStatus.connected) {
        cancelDelayTests();
      }
    });
  }

  void cancelDelayTests() {
    for (final job in _delayTestJobs) {
      job.cancelled = true;
      job.held.clear();
    }
    _delayFlushTimer?.cancel();
    _delayFlushTimer = null;
    _bufferedDelays.clear();
    _bufferedStarts.clear();
    _bufferedFinishes.clear();
    ref.read(pendingDelayTestsProvider.notifier).clear();
  }

  void _scheduleDelayFlush() {
    _delayFlushTimer ??= Timer(renderThrottleDuration, _flushDelayResults);
  }

  void _flushDelayResults() {
    _delayFlushTimer?.cancel();
    _delayFlushTimer = null;
    if (_bufferedDelays.isNotEmpty) {
      final delays = List.of(_bufferedDelays);
      _bufferedDelays.clear();
      ref.read(delayDataSourceProvider.notifier).setDelays(delays);
    }
    if (_bufferedStarts.isNotEmpty || _bufferedFinishes.isNotEmpty) {
      final started = List.of(_bufferedStarts);
      final finished = List.of(_bufferedFinishes);
      _bufferedStarts.clear();
      _bufferedFinishes.clear();
      ref
          .read(pendingDelayTestsProvider.notifier)
          .apply(started: started, finished: finished);
    }
  }

  void updateGroupsDebounce([Duration? duration]) {
    debouncer.call(FunctionTag.updateGroups, updateGroups, duration: duration);
  }

  void changeProxyDebounce(String groupName, String proxyName) {
    final request = _beginSelection(groupName, proxyName);
    _pendingSelections[groupName] = request;
    ref
        .read(profilesActionProvider.notifier)
        .updateCurrentSelectedMap(groupName, proxyName);
    debouncer.call(_selectionTag(groupName), () async {
      if (!_isSelectionCurrent(request)) return;
      _pendingSelections.remove(groupName);
      await _applySelection(request);
      if (_isSelectionCurrent(request)) updateGroupsDebounce();
    });
  }

  Object _selectionTag(String groupName) =>
      (FunctionTag.changeProxy, this, groupName);

  void _invalidateSelections() {
    _selectionEpoch++;
    for (final group in _pendingSelections.keys) {
      debouncer.cancel(_selectionTag(group));
    }
    _pendingSelections.clear();
    _latestSelections.clear();
  }

  _ProxySelectionRequest _beginSelection(String groupName, String proxyName) {
    final previous = _latestSelections[groupName];
    final profileId = ref.read(currentProfileIdProvider);
    final request = _ProxySelectionRequest(
      profileId: profileId,
      epoch: _selectionEpoch,
      groupName: groupName,
      proxyName: proxyName,
      // Overlapping requests share the latest confirmed choice, not an
      // optimistic value or an immutable snapshot taken before earlier replies.
      rollback: previous != null &&
              (!previous.completed || previous.rollback.inFlight > 0) &&
              previous.epoch == _selectionEpoch &&
              previous.profileId == profileId
          ? previous.rollback
          : _SelectionRollback(_currentSelectedName(groupName)),
      order: ++_selectionOrder,
      core: _core,
    );
    _latestSelections[groupName] = request;
    return request;
  }

  bool _isSelectionCurrent(_ProxySelectionRequest request) =>
      ref.mounted &&
      request.epoch == _selectionEpoch &&
      identical(_latestSelections[request.groupName], request) &&
      ref.read(currentProfileIdProvider) == request.profileId &&
      identical(_core, request.core);

  String _currentSelectedName(String groupName) {
    return ref.read(currentProfileProvider)?.selectedMap[groupName] ?? '';
  }

  Future<void> updateGroups() async {
    try {
      ref.read(groupsProvider.notifier).value = await retry(
        task: () async {
          final sortType = ref.read(
            proxiesStyleSettingProvider.select((state) => state.sortType),
          );
          final delayMap = ref.read(delayDataSourceProvider);
          final testUrl = ref.read(
            patchClashConfigProvider.select((state) => state.testUrl),
          );
          final selectedMap = ref.read(
            currentProfileProvider.select((state) => state?.selectedMap ?? {}),
          );
          try {
            return await _core.getProxiesGroups(
              selectedMap: selectedMap,
              sortType: sortType,
              delayMap: delayMap,
              defaultTestUrl: testUrl,
            );
          } catch (e) {
            commonPrint.log(
              'updateGroups error: $e',
              logLevel: coreFailureLogLevel(e),
            );
            return [];
          }
        },
        retryIf: (res) => res.isEmpty,
      );
    } catch (e) {
      // The Core failure path already runs inside the retry task above; a
      // throw here only means ref.read hit a disposed container or the
      // groupsProvider write itself failed.
      commonPrint.log(
        'updateGroups failed: $e',
        logLevel: coreFailureLogLevel(e),
      );
    }
  }

  void updateCurrentGroupName(String groupName) {
    final profile = ref.read(currentProfileProvider);
    if (profile == null || profile.currentGroupName == groupName) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(currentGroupName: groupName));
  }

  void updateCurrentUnfoldSet(Set<String> value) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile == null) return;
    ref
        .read(profilesProvider.notifier)
        .put(currentProfile.copyWith(unfoldSet: value));
  }

  void setDelay(Delay delay) {
    _bufferedDelays.add(delay);
    _scheduleDelayFlush();
  }

  Future<void> changeProxy({
    required String groupName,
    required String proxyName,
  }) async {
    debouncer.cancel(_selectionTag(groupName));
    _pendingSelections.remove(groupName);
    final request = _beginSelection(groupName, proxyName);
    ref.read(profilesActionProvider.notifier)
        .updateCurrentSelectedMap(groupName, proxyName);
    await _applySelection(request);
  }

  Future<void> _applySelection(_ProxySelectionRequest request) async {
    if (!_isSelectionCurrent(request)) return;
    request.rollback.inFlight++;
    try {
      await _dispatchSelection(request);
    } finally {
      request.rollback.inFlight--;
      request.completed = true;
    }
  }

  Future<void> _dispatchSelection(_ProxySelectionRequest request) async {
    final groupName = request.groupName;
    final proxyName = request.proxyName;
    final ChangeProxyResult result;
    try {
      result = await request.core.changeProxy(
        ChangeProxyParams(groupName: groupName, proxyName: proxyName),
      );
      if (result.message.isNotEmpty) {
        throw MessageException(result.message);
      }
    } catch (error) {
      commonPrint.log(
        'changeProxy($groupName -> $proxyName) failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
      request.rejected = true;
      if (!_isSelectionCurrent(request)) return;
      if (_currentSelectedName(groupName) == proxyName) {
        ref.read(profilesActionProvider.notifier)
            .updateCurrentSelectedMap(groupName, request.rollback.name);
      }
      dialogs.showBanner(
        currentAppLocalizations.changeProxyFailedTip,
        level: BannerLevel.error,
      );
      return;
    }
    final latest = _latestSelections[groupName];
    if (latest != null &&
        _isSelectionCurrent(latest) &&
        identical(latest.rollback, request.rollback) &&
        request.order > request.rollback.confirmedOrder) {
      final previousName = request.rollback.name;
      request.rollback
        ..name = proxyName
        ..confirmedOrder = request.order;
      // A newer rejection may have already restored the old baseline while
      // this success was in flight. Reconcile it without overwriting a newer
      // optimistic/accepted choice or resetting that choice's connections.
      if (latest.rejected && _currentSelectedName(groupName) == previousName) {
        ref.read(profilesActionProvider.notifier)
            .updateCurrentSelectedMap(groupName, proxyName);
      }
    }
    if (!_isSelectionCurrent(request) || !result.changed) {
      return;
    }
    try {
      if (ref.read(appSettingProvider).closeConnections) {
        await request.core.closeConnections();
      } else {
        await request.core.resetConnections();
      }
    } catch (error) {
      commonPrint.log(
        'changeProxy($groupName -> $proxyName) connection reset failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }

  Future<void> updateProvider(
    ExternalProvider provider, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref
              .read(updatingKeysProvider.notifier)
              .start(provider.updatingKey, scope: UpdatingScope.core)
        : null;
    try {
      final clashProvidersAction = ref.read(
        clashProvidersActionProvider.notifier,
      );
      final ruleSet = await clashProvidersAction.remoteProviderOf(provider);
      if (ruleSet != null && !await clashProvidersAction.syncRemote(ruleSet)) {
        return;
      }
      await _core.updateExternalProvider(provider.name);
      ref
          .read(providersProvider.notifier)
          .setProvider(await _core.getExternalProvider(provider.name));
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(provider.updatingKey, operation);
      }
    }
  }

  Future<void> sideLoadExternalProvider(
    ExternalProvider provider,
    String data, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref
              .read(updatingKeysProvider.notifier)
              .start(provider.updatingKey, scope: UpdatingScope.core)
        : null;
    try {
      await _core.sideLoadExternalProvider(
        providerName: provider.name,
        data: data,
      );
      ref
          .read(providersProvider.notifier)
          .setProvider(await _core.getExternalProvider(provider.name));
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(provider.updatingKey, operation);
      }
    }
  }

  Future<void> addToLocalProxies(String proxyName) async {
    final appLocalizations = currentAppLocalizations;
    final definition = await _core.getProxyDefinition(proxyName);
    if (definition == null) {
      throw MessageException(
        appLocalizations.customIssueMissingProxies(proxyName),
      );
    }
    final (proxies, groupNames) = await (
      database.customProxiesDao.query().get(),
      database.proxyGroupsDao.names().get(),
    ).wait;
    final (:name, :added) = importProxy(
      definition,
      existing: [for (final proxy in proxies) proxy.definition],
      groupNames: groupNames.toSet(),
    );
    if (added == null) {
      dialogs.showBanner(appLocalizations.alreadyInLocalProxies(name));
      return;
    }
    final order = indexing.generateKeyBetween(
      proxies.map((proxy) => proxy.order).nonNulls.lastOrNull,
      null,
    );
    await database.customProxies.put(
      CustomProxy.fromDefinition(added).copyWith(order: order).toCompanion(),
    );
    dialogs.showBanner(appLocalizations.addedToLocalProxies(name));
  }

  Future<Delay?> proxyDelayTest(Proxy proxy, [String? testUrl]) async {
    final results = await _runDelayTests([
      (proxies: [proxy], testUrl: testUrl),
    ]);
    return results.firstOrNull;
  }

  Future<void> delayTest(List<Proxy> proxies, [String? testUrl]) async {
    await _runDelayTests([(proxies: proxies, testUrl: testUrl)]);
    ref.read(sortNumProvider.notifier).add();
  }

  Future<void> delayTestGroups(List<Group> groups) async {
    await _runDelayTests([
      for (final group in groups) (proxies: group.all, testUrl: group.testUrl),
    ]);
    ref.read(sortNumProvider.notifier).add();
  }

  Future<void> delayTestPageGroup(
    String groupName, {
    bool matchSearch = true,
  }) async {
    final group = ref.read(groupsProvider).getGroup(groupName);
    if (group == null) {
      return;
    }
    final testing = ref.read(delayTestingGroupsProvider.notifier);
    if (!testing.start(groupName)) {
      return;
    }
    try {
      final query = SearchQuery(
        matchSearch ? ref.read(queryProvider(QueryTag.proxies)) : '',
      );
      await delayTest(
        group.all.whereMatches(query, (proxy) => proxy.searchFields).toList(),
        group.testUrl,
      );
    } finally {
      testing.stop(groupName);
    }
  }

  List<_DelayTestTarget> _resolveDelayTestTargets(
    List<_DelayTestBatch> batches,
  ) {
    final groups = ref.read(groupsProvider);
    final selectedMap = ref.read(
      currentProfileProvider.select((state) => state?.selectedMap ?? {}),
    );
    final seen = <String>{};
    final targets = <_DelayTestTarget>[];
    for (final batch in batches) {
      final fallbackTestUrl = ref.read(realTestUrlProvider(batch.testUrl));
      for (final proxy in batch.proxies) {
        final state = computeRealSelectedProxyState(
          proxy.name,
          groups: groups,
          selectedMap: selectedMap,
        );
        if (state.proxyName.isEmpty) {
          continue;
        }
        final currentTestUrl = state.testUrl.takeFirstValid([fallbackTestUrl]);
        final key = delayTestKey(currentTestUrl, state.proxyName);
        if (!seen.add(key)) {
          continue;
        }
        targets.add(
          _DelayTestTarget(
            proxyName: state.proxyName,
            testUrl: currentTestUrl,
            key: key,
          ),
        );
      }
    }
    return targets;
  }

  Future<List<Delay>> _runDelayTests(List<_DelayTestBatch> batches) async {
    final targets = _resolveDelayTestTargets(batches);
    if (targets.isEmpty) {
      return const [];
    }
    final pending = ref.read(pendingDelayTestsProvider.notifier);
    final job = _DelayTestJob(
      targets.map((target) => target.key),
      Duration(milliseconds: ref.read(appSettingProvider).delayTestTimeout),
    );
    _delayTestJobs.add(job);
    // TaskPool.run starts a task synchronously while it has an idle slot.
    job.startedOnDispatch.addAll(
      targets.take(_delayTestPool.idleSlots).map((target) => target.key),
    );
    pending.apply(acquired: job.held, started: job.startedOnDispatch);
    try {
      await Future.wait(
        targets.map(
          (target) => _delayTestPool.run(() => _runDelayTest(job, target)),
        ),
      );
    } finally {
      _delayTestJobs.remove(job);
      _flushDelayResults();
      final abandoned = job.held.toList();
      job.held.clear();
      pending.apply(
        finished: abandoned.where(job.startedOnDispatch.contains),
        released: abandoned.where(
          (key) => !job.startedOnDispatch.contains(key),
        ),
      );
    }
    return job.results;
  }

  Future<void> _runDelayTest(_DelayTestJob job, _DelayTestTarget target) async {
    if (job.cancelled) {
      return;
    }
    if (!job.startedOnDispatch.contains(target.key)) {
      _bufferedStarts.add(target.key);
      _scheduleDelayFlush();
    }
    try {
      final delay = await _core.testDelay(
        TestDelayParams(
          proxyName: target.proxyName,
          testUrl: target.testUrl,
          timeout: job.timeout.inMilliseconds,
        ),
      );
      if (!job.cancelled) {
        job.results.add(delay);
        setDelay(delay);
      }
    } catch (error) {
      if (error is CoreMethodException && error.isCoreUnavailable) {
        job.cancelled = true;
      }
      commonPrint.log(
        'Delay test failed for ${target.proxyName}: $error',
        logLevel: coreFailureLogLevel(error),
      );
    } finally {
      if (job.held.remove(target.key)) {
        _bufferedFinishes.add(target.key);
        _scheduleDelayFlush();
      }
    }
  }
}
