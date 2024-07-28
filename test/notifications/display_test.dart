import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:collection/collection.dart';
import 'package:fake_async/fake_async.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message, Person;
import 'package:flutter_test/flutter_test.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/notifications.dart';
import 'package:zulip/host/android_notifications.dart';
import 'package:zulip/model/localizations.dart';
import 'package:zulip/model/narrow.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/notifications/display.dart';
import 'package:zulip/notifications/receive.dart';
import 'package:zulip/widgets/app.dart';
import 'package:zulip/widgets/inbox.dart';
import 'package:zulip/widgets/message_list.dart';
import 'package:zulip/widgets/page.dart';
import 'package:zulip/widgets/theme.dart';

import '../fake_async.dart';
import '../model/binding.dart';
import '../example_data.dart' as eg;
import '../test_navigation.dart';
import '../widgets/message_list_checks.dart';
import '../widgets/page_checks.dart';

MessageFcmMessage messageFcmMessage(
  Message zulipMessage, {
  String? streamName,
  Account? account,
}) {
  account ??= eg.selfAccount;
  final narrow = SendableNarrow.ofMessage(zulipMessage, selfUserId: account.userId);
  return FcmMessage.fromJson({
    "event": "message",

    "server": "zulip.example.cloud",
    "realm_id": "4",
    "realm_uri": account.realmUrl.toString(),
    "user_id": account.userId.toString(),

    "zulip_message_id": zulipMessage.id.toString(),
    "time": zulipMessage.timestamp.toString(),
    "content": zulipMessage.content,

    "sender_id": zulipMessage.senderId.toString(),
    "sender_avatar_url": "${account.realmUrl}avatar/${zulipMessage.senderId}.jpeg",
    "sender_full_name": zulipMessage.senderFullName.toString(),

    ...(switch (narrow) {
      TopicNarrow(:var streamId, :var topic) => {
        "recipient_type": "stream",
        "stream_id": streamId.toString(),
        if (streamName != null) "stream": streamName,
        "topic": topic,
      },
      DmNarrow(allRecipientIds: [_, _, _, ...]) => {
        "recipient_type": "private",
        "pm_users": narrow.allRecipientIds.join(","),
      },
      DmNarrow() => {
        "recipient_type": "private",
      },
    }),
  }) as MessageFcmMessage;
}

void main() {
  TestZulipBinding.ensureInitialized();
  final zulipLocalizations = GlobalLocalizations.zulipLocalizations;

  Future<void> init() async {
    addTearDown(testBinding.reset);
    testBinding.firebaseMessagingInitialToken = '012abc';
    addTearDown(NotificationService.debugReset);
    NotificationService.debugBackgroundIsolateIsLive = false;
    await NotificationService.instance.start();
  }

  group('NotificationChannelManager', () {
    test('smoke', () async {
      await init();
      check(testBinding.androidNotificationHost.takeCreatedChannels()).single
        ..id.equals(NotificationChannelManager.kChannelId)
        ..name.equals('Messages')
        ..importance.equals(NotificationImportance.high)
        ..lightsEnabled.equals(true)
        ..vibrationPattern.isNotNull().deepEquals(
            NotificationChannelManager.kVibrationPattern)
      ;
    });
  });

  group('NotificationDisplayManager show', () {
    void checkNotification(MessageFcmMessage data, {
      required List<MessageFcmMessage> messageStyleMessages,
      required String expectedTitle,
      required String expectedTagComponent,
      required bool expectedIsGroupConversation,
    }) {
      final expectedTag = '${data.realmUri}|${data.userId}|$expectedTagComponent';
      final expectedGroupKey = '${data.realmUri}|${data.userId}';
      final expectedId =
        NotificationDisplayManager.notificationIdAsHashOf(expectedTag);
      const expectedIntentFlags =
        PendingIntentFlag.immutable | PendingIntentFlag.updateCurrent;
      final expectedSelfUserKey = '${data.realmUri}|${data.userId}';

      final messageStyleMessagesChecks =
        messageStyleMessages.mapIndexed((i, messageData) {
          assert(messageData.realmUri == data.realmUri);
          assert(messageData.userId == data.userId);

          final expectedSenderKey =
            '${messageData.realmUri}|${messageData.senderId}';
          final isLast = i == (messageStyleMessages.length - 1);
          return (Subject<Object?> it) => it.isA<MessagingStyleMessage>()
            ..text.equals(messageData.content)
            ..timestampMs.equals(messageData.time * 1000)
            ..person.which((it) => it.isNotNull()
              ..iconBitmap.which((it) => isLast ? it.isNotNull() : it.isNull())
              ..key.equals(expectedSenderKey)
              ..name.equals(messageData.senderFullName));
        });

      check(testBinding.androidNotificationHost.takeNotifyCalls())
        .deepEquals(<Condition<Object?>>[
          (it) => it.isA<AndroidNotificationHostApiNotifyCall>()
            ..id.equals(expectedId)
            ..tag.equals(expectedTag)
            ..channelId.equals(NotificationChannelManager.kChannelId)
            ..contentTitle.isNull()
            ..contentText.isNull()
            ..messagingStyle.which((it) => it.isNotNull()
              ..user.which((it) => it
                ..iconBitmap.isNull()
                ..key.equals(expectedSelfUserKey)
                ..name.equals(zulipLocalizations.notifSelfUser))
              ..isGroupConversation.equals(expectedIsGroupConversation)
              ..conversationTitle.equals(expectedTitle)
              ..messages.deepEquals(messageStyleMessagesChecks))
            ..number.equals(messageStyleMessages.length)
            ..color.equals(kZulipBrandColor.value)
            ..smallIconResourceName.equals('zulip_notification')
            ..extras.isNull()
            ..groupKey.equals(expectedGroupKey)
            ..isGroupSummary.isNull()
            ..inboxStyle.isNull()
            ..autoCancel.equals(true)
            ..contentIntent.which((it) => it.isNotNull()
              ..requestCode.equals(expectedId)
              ..flags.equals(expectedIntentFlags)
              ..intentPayload.equals(jsonEncode(data.toJson()))),
          (it) => it.isA<AndroidNotificationHostApiNotifyCall>()
            ..id.equals(NotificationDisplayManager.notificationIdAsHashOf(expectedGroupKey))
            ..tag.equals(expectedGroupKey)
            ..channelId.equals(NotificationChannelManager.kChannelId)
            ..contentTitle.isNull()
            ..contentText.isNull()
            ..color.equals(kZulipBrandColor.value)
            ..smallIconResourceName.equals('zulip_notification')
            ..extras.isNull()
            ..groupKey.equals(expectedGroupKey)
            ..isGroupSummary.equals(true)
            ..inboxStyle.which((it) => it.isNotNull()
              ..summaryText.equals(data.realmUri.toString()))
            ..autoCancel.equals(true)
            ..contentIntent.isNull(),
        ]);
    }

    Future<void> checkNotifications(FakeAsync async, MessageFcmMessage data, {
      required String expectedTitle,
      required String expectedTagComponent,
      required bool expectedIsGroupConversation,
    }) async {
      // We could just call `NotificationDisplayManager.onFcmMessage`.
      // But this way is cheap, and it provides our test coverage of
      // the logic in `NotificationService` that listens for these FCM messages.

      testBinding.firebaseMessaging.onMessage.add(
        RemoteMessage(data: data.toJson()));
      async.flushMicrotasks();
      checkNotification(data,
        messageStyleMessages: [data],
        expectedIsGroupConversation: expectedIsGroupConversation,
        expectedTitle: expectedTitle,
        expectedTagComponent: expectedTagComponent);
      testBinding.androidNotificationHost.clearActiveNotifications();

      testBinding.firebaseMessaging.onBackgroundMessage.add(
        RemoteMessage(data: data.toJson()));
      async.flushMicrotasks();
      checkNotification(data,
        messageStyleMessages: [data],
        expectedIsGroupConversation: expectedIsGroupConversation,
        expectedTitle: expectedTitle,
        expectedTagComponent: expectedTagComponent);
    }

    Future<void> receiveFcmMessage(FakeAsync async, MessageFcmMessage data) async {
      testBinding.firebaseMessaging.onMessage.add(
        RemoteMessage(data: data.toJson()));
      async.flushMicrotasks();
    }

    test('stream message', () => awaitFakeAsync((async) async {
      await init();
      final stream = eg.stream();
      final message = eg.streamMessage(stream: stream);
      await checkNotifications(async, messageFcmMessage(message, streamName: stream.name),
        expectedIsGroupConversation: true,
        expectedTitle: '#${stream.name} > ${message.topic}',
        expectedTagComponent: 'stream:${message.streamId}:${message.topic}');
    }));

    test('stream message: multiple messages, same topic', () => awaitFakeAsync((async) async {
      await init();
      final stream = eg.stream();
      const topic = 'topic 1';
      final message1 = eg.streamMessage(topic: topic, stream: stream);
      final data1 = messageFcmMessage(message1, streamName: stream.name);
      final message2 = eg.streamMessage(topic: topic, stream: stream);
      final data2 = messageFcmMessage(message2, streamName: stream.name);
      final message3 = eg.streamMessage(topic: topic, stream: stream);
      final data3 = messageFcmMessage(message3, streamName: stream.name);

      final expectedTitle = '#${stream.name} > $topic';
      final expectedTagComponent = 'stream:${stream.streamId}:$topic';

      await receiveFcmMessage(async, data1);
      checkNotification(data1,
        messageStyleMessages: [data1],
        expectedIsGroupConversation: true,
        expectedTitle: expectedTitle,
        expectedTagComponent: expectedTagComponent);

      await receiveFcmMessage(async, data2);
      checkNotification(data2,
        messageStyleMessages: [data1, data2],
        expectedIsGroupConversation: true,
        expectedTitle: expectedTitle,
        expectedTagComponent: expectedTagComponent);

      await receiveFcmMessage(async, data3);
      checkNotification(data3,
        messageStyleMessages: [data1, data2, data3],
        expectedIsGroupConversation: true,
        expectedTitle: expectedTitle,
        expectedTagComponent: expectedTagComponent);
    }));

    test('stream message: stream name omitted', () => awaitFakeAsync((async) async {
      await init();
      final stream = eg.stream();
      final message = eg.streamMessage(stream: stream);
      await checkNotifications(async, messageFcmMessage(message, streamName: null),
        expectedIsGroupConversation: true,
        expectedTitle: '#(unknown channel) > ${message.topic}',
        expectedTagComponent: 'stream:${message.streamId}:${message.topic}');
    }));

    test('group DM: 3 users', () => awaitFakeAsync((async) async {
      await init();
      final message = eg.dmMessage(from: eg.thirdUser, to: [eg.otherUser, eg.selfUser]);
      await checkNotifications(async, messageFcmMessage(message),
        expectedIsGroupConversation: true,
        expectedTitle: "${eg.thirdUser.fullName} to you and 1 other",
        expectedTagComponent: 'dm:${message.allRecipientIds.join(",")}');
    }));

    test('group DM: more than 3 users', () => awaitFakeAsync((async) async {
      await init();
      final message = eg.dmMessage(from: eg.thirdUser,
        to: [eg.otherUser, eg.selfUser, eg.fourthUser]);
      await checkNotifications(async, messageFcmMessage(message),
        expectedIsGroupConversation: true,
        expectedTitle: "${eg.thirdUser.fullName} to you and 2 others",
        expectedTagComponent: 'dm:${message.allRecipientIds.join(",")}');
    }));

    test('1:1 DM', () => awaitFakeAsync((async) async {
      await init();
      final message = eg.dmMessage(from: eg.otherUser, to: [eg.selfUser]);
      await checkNotifications(async, messageFcmMessage(message),
        expectedIsGroupConversation: false,
        expectedTitle: eg.otherUser.fullName,
        expectedTagComponent: 'dm:${message.allRecipientIds.join(",")}');
    }));

    test('self-DM', () => awaitFakeAsync((async) async {
      await init();
      final message = eg.dmMessage(from: eg.selfUser, to: []);
      await checkNotifications(async, messageFcmMessage(message),
        expectedIsGroupConversation: false,
        expectedTitle: eg.selfUser.fullName,
        expectedTagComponent: 'dm:${message.allRecipientIds.join(",")}');
    }));
  });

  group('NotificationDisplayManager open', () {
    late List<Route<void>> pushedRoutes;

    void takeStartingRoutes({bool withAccount = true}) {
      final expected = <Condition<Object?>>[
        (it) => it.isA<WidgetRoute>().page.isA<ChooseAccountPage>(),
        if (withAccount) ...[
          (it) => it.isA<MaterialAccountWidgetRoute>()
            ..accountId.equals(eg.selfAccount.id)
            ..page.isA<HomePage>(),
          (it) => it.isA<MaterialAccountWidgetRoute>()
            ..accountId.equals(eg.selfAccount.id)
            ..page.isA<InboxPage>(),
        ],
      ];
      check(pushedRoutes.take(expected.length)).deepEquals(expected);
      pushedRoutes.removeRange(0, expected.length);
    }

    Future<void> prepare(WidgetTester tester,
        {bool early = false, bool withAccount = true}) async {
      await init();
      pushedRoutes = [];
      final testNavObserver = TestNavigatorObserver()
        ..onPushed = (route, prevRoute) => pushedRoutes.add(route);
      // This uses [ZulipApp] instead of [TestZulipApp] because notification
      // logic uses `await ZulipApp.navigator`.
      await tester.pumpWidget(ZulipApp(navigatorObservers: [testNavObserver]));
      if (early) {
        check(pushedRoutes).isEmpty();
        return;
      }
      await tester.pump();
      takeStartingRoutes(withAccount: withAccount);
      check(pushedRoutes).isEmpty();
    }

    Future<void> openNotification(WidgetTester tester, Account account, Message message) async {
      final fcmMessage = messageFcmMessage(message, account: account);
      testBinding.notifications.receiveNotificationResponse(NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: jsonEncode(fcmMessage)));
      await tester.idle(); // let _navigateForNotification find navigator
    }

    void matchesNavigation(Subject<Route<void>> route, Account account, Message message) {
      route.isA<MaterialAccountWidgetRoute>()
        ..accountId.equals(account.id)
        ..page.isA<MessageListPage>()
          .narrow.equals(SendableNarrow.ofMessage(message,
            selfUserId: account.userId));
    }

    Future<void> checkOpenNotification(WidgetTester tester, Account account, Message message) async {
      await openNotification(tester, account, message);
      matchesNavigation(check(pushedRoutes).single, account, message);
      pushedRoutes.clear();
    }

    testWidgets('stream message', (tester) async {
      testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
      await prepare(tester);
      await checkOpenNotification(tester, eg.selfAccount, eg.streamMessage());
    });

    testWidgets('direct message', (tester) async {
      testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
      await prepare(tester);
      await checkOpenNotification(tester, eg.selfAccount,
        eg.dmMessage(from: eg.otherUser, to: [eg.selfUser]));
    });

    testWidgets('no accounts', (tester) async {
      await prepare(tester, withAccount: false);
      await openNotification(tester, eg.selfAccount, eg.streamMessage());
      check(pushedRoutes).isEmpty();
    });

    testWidgets('mismatching account', (tester) async {
      testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
      await prepare(tester);
      await openNotification(tester, eg.otherAccount, eg.streamMessage());
      check(pushedRoutes).isEmpty();
    });

    testWidgets('find account among several', (tester) async {
      final realmUrlA = Uri.parse('https://a-chat.example/');
      final realmUrlB = Uri.parse('https://chat-b.example/');
      final user1 = eg.user();
      final user2 = eg.user();
      final accounts = [
        eg.account(id: 1001, realmUrl: realmUrlA, user: user1),
        eg.account(id: 1002, realmUrl: realmUrlA, user: user2),
        eg.account(id: 1003, realmUrl: realmUrlB, user: user1),
        eg.account(id: 1004, realmUrl: realmUrlB, user: user2),
      ];
      for (final account in accounts) {
        testBinding.globalStore.add(account, eg.initialSnapshot());
      }
      await prepare(tester);

      await checkOpenNotification(tester, accounts[0], eg.streamMessage());
      await checkOpenNotification(tester, accounts[1], eg.streamMessage());
      await checkOpenNotification(tester, accounts[2], eg.streamMessage());
      await checkOpenNotification(tester, accounts[3], eg.streamMessage());
    });

    testWidgets('wait for app to become ready', (tester) async {
      testBinding.globalStore.add(eg.selfAccount, eg.initialSnapshot());
      await prepare(tester, early: true);
      final message = eg.streamMessage();
      await openNotification(tester, eg.selfAccount, message);
      // The app should still not be ready (or else this test won't work right).
      check(ZulipApp.ready.value).isFalse();
      check(ZulipApp.navigatorKey.currentState).isNull();
      // And the openNotification hasn't caused any navigation yet.
      check(pushedRoutes).isEmpty();

      // Now let the GlobalStore get loaded and the app's main UI get mounted.
      await tester.pump();
      // The navigator first pushes the starting routes…
      takeStartingRoutes();
      // … and then the one the notification leads to.
      matchesNavigation(check(pushedRoutes).single, eg.selfAccount, message);
    });

    testWidgets('at app launch', (tester) async {
      // Set up a value for `getNotificationLaunchDetails` to return.
      final account = eg.selfAccount;
      final message = eg.streamMessage();
      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: jsonEncode(messageFcmMessage(message, account: account)));
      testBinding.notifications.appLaunchDetails =
        NotificationAppLaunchDetails(true, notificationResponse: response);

      // Now start the app.
      testBinding.globalStore.add(account, eg.initialSnapshot());
      await prepare(tester, early: true);
      check(pushedRoutes).isEmpty(); // GlobalStore hasn't loaded yet

      // Once the app is ready, we navigate to the conversation.
      await tester.pump();
      takeStartingRoutes();
      matchesNavigation(check(pushedRoutes).single, account, message);
    });
  });
}

extension NotificationChannelChecks on Subject<NotificationChannel> {
  Subject<String> get id => has((x) => x.id, 'id');
  Subject<int> get importance => has((x) => x.importance, 'importance');
  Subject<String?> get name => has((x) => x.name, 'name');
  Subject<bool?> get lightsEnabled => has((x) => x.lightsEnabled, 'lightsEnabled');
  Subject<Int64List?> get vibrationPattern => has((x) => x.vibrationPattern, 'vibrationPattern');
}

extension on Subject<AndroidNotificationHostApiNotifyCall> {
  Subject<String?> get tag => has((x) => x.tag, 'tag');
  Subject<int> get id => has((x) => x.id, 'id');
  Subject<bool?> get autoCancel => has((x) => x.autoCancel, 'autoCancel');
  Subject<String> get channelId => has((x) => x.channelId, 'channelId');
  Subject<int?> get color => has((x) => x.color, 'color');
  Subject<PendingIntent?> get contentIntent => has((x) => x.contentIntent, 'contentIntent');
  Subject<String?> get contentText => has((x) => x.contentText, 'contentText');
  Subject<String?> get contentTitle => has((x) => x.contentTitle, 'contentTitle');
  Subject<Map<String?, String?>?> get extras => has((x) => x.extras, 'extras');
  Subject<String?> get groupKey => has((x) => x.groupKey, 'groupKey');
  Subject<InboxStyle?> get inboxStyle => has((x) => x.inboxStyle, 'inboxStyle');
  Subject<bool?> get isGroupSummary => has((x) => x.isGroupSummary, 'isGroupSummary');
  Subject<MessagingStyle?> get messagingStyle => has((x) => x.messagingStyle, 'messagingStyle');
  Subject<int?> get number => has((x) => x.number, 'number');
  Subject<String?> get smallIconResourceName => has((x) => x.smallIconResourceName, 'smallIconResourceName');
}

extension on Subject<PendingIntent> {
  Subject<int> get requestCode => has((x) => x.requestCode, 'requestCode');
  Subject<String> get intentPayload => has((x) => x.intentPayload, 'intentPayload');
  Subject<int> get flags => has((x) => x.flags, 'flags');
}

extension on Subject<InboxStyle> {
  Subject<String> get summaryText => has((x) => x.summaryText, 'summaryText');
}

extension on Subject<MessagingStyle> {
  Subject<Person> get user => has((x) => x.user, 'user');
  Subject<String?> get conversationTitle => has((x) => x.conversationTitle, 'conversationTitle');
  Subject<List<MessagingStyleMessage?>> get messages => has((x) => x.messages, 'messages');
  Subject<bool> get isGroupConversation => has((x) => x.isGroupConversation, 'isGroupConversation');
}

extension on Subject<Person> {
  Subject<Uint8List?> get iconBitmap => has((x) => x.iconBitmap, 'iconBitmap');
  Subject<String> get key => has((x) => x.key, 'key');
  Subject<String> get name => has((x) => x.name, 'name');
}

extension on Subject<MessagingStyleMessage> {
  Subject<String> get text => has((x) => x.text, 'text');
  Subject<int> get timestampMs => has((x) => x.timestampMs, 'timestampMs');
  Subject<Person> get person => has((x) => x.person, 'person');
}
