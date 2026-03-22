import 'package:flutter/material.dart';
import 'package:isometrik_flutter_call/isometrik_flutter_call.dart';
import 'package:provider/provider.dart';

import '../app/example_app_controller.dart';
import 'create_meeting_page.dart';

/// Mirrors [Example/MyMeetingsViewController.swift]: list, pull to refresh, Join, swipe to leave.
class MeetingsPage extends StatefulWidget {
  const MeetingsPage({super.key});

  @override
  State<MeetingsPage> createState() => _MeetingsPageState();
}

class _MeetingsPageState extends State<MeetingsPage> {
  Future<List<IsometrikMeeting>>? _future;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _reload();
      }
    });
  }

  void _reload() {
    final c = context.read<ExampleAppController>();
    setState(() {
      _future = c.loadMeetings();
    });
  }

  /// Join an existing meeting and show the SDK's built-in call page.
  Future<void> _joinAndShowCallPage(
    ExampleAppController c,
    IsometrikMeeting meeting,
  ) async {
    final joined = await c.joinMeetingAndStartNative(meeting.meetingId ?? '');
    if (!mounted) return;
    if (joined == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Join failed')),
      );
      return;
    }
    final controller = IsometrikCallController(
      sdk: c.sdk,
      meetingId: joined.meetingId ?? meeting.meetingId ?? '',
      peerName: joined.initiatorName ?? 'Peer',
      isOutgoing: false,
      hasVideo: joined.callType != IsometrikLiveCallType.audioCall,
      rtcToken: joined.rtcToken,
      initialStatus: IsometrikCallStatus.connecting,
    );
    if (!mounted) return;
    await IsometrikCallPage.show(
      context,
      controller: controller,
      config: const IsometrikCallPageConfig(showMeetingIdDebug: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ExampleAppController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Meetings'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (BuildContext ctx) => AlertDialog(
                  title: const Text('Log out?'),
                  content: const Text(
                    'Another user can sign in after logout. Stored tokens are cleared.',
                  ),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Log out'),
                    ),
                  ],
                ),
              );
              if (ok == true && context.mounted) {
                await c.signOut();
              }
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: FutureBuilder<List<IsometrikMeeting>>(
          future: _future,
          builder: (BuildContext context, AsyncSnapshot<List<IsometrikMeeting>> s) {
            if (_future == null ||
                (s.connectionState == ConnectionState.waiting && !s.hasData)) {
              return const Center(child: CircularProgressIndicator());
            }
            if (s.hasError) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Error: ${s.error}'),
                  ),
                ],
              );
            }
            final list = s.data ?? <IsometrikMeeting>[];
            if (list.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const <Widget>[
                  SizedBox(height: 120),
                  Center(child: Text('No meetings found.')),
                ],
              );
            }
            return ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: list.length,
              itemBuilder: (BuildContext context, int i) {
                final m = list[i];
                final id = m.meetingId ?? '';
                final title = m.meetingDescription ?? '(no title)';
                return Dismissible(
                  key: ValueKey<String>(id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red.shade700,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (DismissDirection d) async {
                    try {
                      await c.leaveMeeting(id);
                      return true;
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('$e')),
                        );
                      }
                      return false;
                    }
                  },
                  child: ListTile(
                    title: Text(title, style: const TextStyle(fontSize: 17)),
                    subtitle: Text(
                      'id: $id',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: FilledButton(
                      onPressed: () => _joinAndShowCallPage(c, m),
                      child: const Text('Join'),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Create call / meeting',
        onPressed: () async {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (BuildContext ctx) => const CreateMeetingPage(),
            ),
          );
          _reload();
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
