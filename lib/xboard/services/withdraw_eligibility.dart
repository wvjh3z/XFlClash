import '../models/xb_invite.dart';
import '../util/money_input.dart';

const withdrawMinimumCents = 20000;
const withdrawMinimumPaidRecords = 10;

// The legacy SDK defaults a missing commission_balance to zero.
int? withdrawBalanceCents(double amountYuan) =>
    parseYuanCents(amountYuan.toString());

/// Xboard's first page contains only positive, already paid commission logs.
/// Fetching [withdrawMinimumPaidRecords] rows is enough to prove the threshold;
/// registrations and pending commissions are unrelated.
int? withdrawPaidRecordCount(List<XbCommissionRecord> records) {
  // The legacy SDK folds a missing/malformed data envelope into an empty list.
  // Without the envelope, zero cannot be distinguished from an unknown result.
  if (records.isEmpty) return null;
  final ids = <int>{};
  for (final record in records) {
    if (record.id <= 0 ||
        !record.getAmountYuan.isFinite ||
        record.getAmountYuan <= 0 ||
        !ids.add(record.id)) {
      return null;
    }
  }
  return ids.length;
}
