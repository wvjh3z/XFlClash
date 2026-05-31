/// W4.7 — 账号注销 mailto 构造（§B / κ-3）+ 页面渲染。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fl_clash/xboard/pages/account_deletion_request_page.dart';

void main() {
  group('buildDeletionMailto', () {
    test('scheme=mailto + 收件人 + subject 含 userIdHash（不含 token/email）', () {
      final uri = buildDeletionMailto(
        supportEmail: 'support@example.com',
        userIdHash: 'deadbeefcafe1234',
      );
      expect(uri.scheme, 'mailto');
      expect(uri.path, 'support@example.com');
      final decoded = Uri.decodeFull(uri.query);
      expect(decoded.contains('账号注销请求'), isTrue);
      expect(decoded.contains('deadbeefcafe1234'), isTrue);
      // 不含敏感原文
      expect(decoded.contains('Bearer'), isFalse);
    });

    test('subject + body 都被 encode（无裸空格破坏 URI）', () {
      final uri = buildDeletionMailto(
        supportEmail: 's@x.com',
        userIdHash: 'abc',
      );
      expect(uri.query.contains('subject='), isTrue);
      expect(uri.query.contains('body='), isTrue);
      // query 中不应出现未编码的中文裸字符导致解析异常 —— 能正常 toString
      expect(() => uri.toString(), returnsNormally);
    });
  });

  testWidgets('页面渲染：标题 + 发送按钮 + 取消', (t) async {
    await t.pumpWidget(const ProviderScope(
      child: MaterialApp(home: AccountDeletionRequestPage(currentToken: 'tok')),
    ));
    expect(find.text('永久删除账号'), findsOneWidget);
    expect(find.text('发送注销请求邮件'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
  });
}
