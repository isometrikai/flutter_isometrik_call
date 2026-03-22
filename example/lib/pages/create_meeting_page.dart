import 'package:flutter/material.dart';
import 'package:isometrik_flutter_call/isometrik_flutter_call.dart';
import 'package:provider/provider.dart';

import '../app/example_app_controller.dart';
import 'search_users_page.dart';

/// Mirrors [Example/CreateMeetingViewController.swift] + member search sheet.
class CreateMeetingPage extends StatefulWidget {
  const CreateMeetingPage({super.key});

  @override
  State<CreateMeetingPage> createState() => _CreateMeetingPageState();
}

class _CreateMeetingPageState extends State<CreateMeetingPage> {
  final TextEditingController _title = TextEditingController();
  List<IsometrikDirectoryUser> _members = <IsometrikDirectoryUser>[];
  bool _audioOnly = false;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  IsometrikLiveCallType _resolveCallType() {
    if (_members.length > 1) {
      return IsometrikLiveCallType.groupCall;
    }
    return _audioOnly
        ? IsometrikLiveCallType.audioCall
        : IsometrikLiveCallType.videoCall;
  }

  Future<void> _pickMembers() async {
    final list = await Navigator.of(context).push<List<IsometrikDirectoryUser>>(
      MaterialPageRoute<List<IsometrikDirectoryUser>>(
        builder: (BuildContext ctx) => const SearchUsersPage(),
      ),
    );
    if (list != null && mounted) {
      setState(() => _members = list);
    }
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please add a meeting title')),
      );
      return;
    }
    if (_members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one member')),
      );
      return;
    }
    setState(() => _busy = true);
    final c = context.read<ExampleAppController>();

    // Use SDK's startCall for 1:1 calls, or createMeetingWithMembers for group.
    final callType = _resolveCallType();
    IsometrikCallController? controller;

    try {
      if (_members.length == 1) {
        // 1:1 call — use SDK convenience which creates meeting + CallKit.
        controller = await c.sdk.startCall(
          memberId: _members.first.userId,
          memberName: _members.first.userName,
          memberImageUrl: _members.first.userProfileImageUrl.isNotEmpty
              ? _members.first.userProfileImageUrl
              : null,
          callType: callType,
        );
      } else {
        // Group call — use multi-member API.
        final ids =
            _members.map((IsometrikDirectoryUser u) => u.userId).toList();
        final meeting = await c.createMeetingWithMembers(
          memberIds: ids,
          meetingTitle: title,
          callType: callType,
        );
        if (meeting != null && meeting.meetingId != null) {
          controller = IsometrikCallController(
            sdk: c.sdk,
            meetingId: meeting.meetingId!,
            peerName: _members.map((u) => u.userName).join(', '),
            isOutgoing: true,
            hasVideo: callType != IsometrikLiveCallType.audioCall,
            rtcToken: meeting.rtcToken,
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (!mounted) return;
    if (controller == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Create call failed')),
      );
      return;
    }
    if (!context.mounted) return;
    // Replace current page with the SDK's call page.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => IsometrikCallPage(
          controller: controller!,
          config: const IsometrikCallPageConfig(showMeetingIdDebug: true),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final names = _members.map((IsometrikDirectoryUser u) => u.userName).join(', ');
    return Scaffold(
      appBar: AppBar(title: const Text('New meeting / call')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          const Text('Meeting title'),
          const SizedBox(height: 8),
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Enter meeting title',
            ),
          ),
          const SizedBox(height: 20),
          const Text('Members (search API)'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickMembers,
            icon: const Icon(Icons.person_search),
            label: Text(
              _members.isEmpty ? 'Add members' : names,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 16),
          if (_members.length <= 1) ...<Widget>[
            SwitchListTile(
              title: const Text('Audio only (1:1)'),
              value: _audioOnly,
              onChanged: (bool v) => setState(() => _audioOnly = v),
            ),
          ] else
            const ListTile(
              title: Text('Group call'),
              subtitle: Text('Uses GroupCall type when 2+ members'),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _create,
            child: Text(_busy ? 'Creating…' : 'Create'),
          ),
        ],
      ),
    );
  }
}
