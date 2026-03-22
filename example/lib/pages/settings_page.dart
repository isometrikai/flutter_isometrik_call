import 'package:flutter/material.dart';
import 'package:isometrik_flutter_call/isometrik_flutter_call.dart';
import 'package:provider/provider.dart';

import '../app/example_app_controller.dart';

/// Diagnostics & simulations: MQTT, native CallKit tests, HTTP trace (same data as console logs).
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final c = context.watch<ExampleAppController>();
    final session = c.authSession;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings & diagnostics')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text(
            'Signed-in user',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          ListTile(
            title: const Text('Email'),
            subtitle: Text(c.signedInEmail ?? '—'),
          ),
          ListTile(
            title: const Text('User id'),
            subtitle: Text(session?.userId ?? '—'),
          ),
          ListTile(
            title: const Text('Token (truncated)'),
            subtitle: Text(
              session == null
                  ? '—'
                  : session.userToken.length <= 32
                  ? session.userToken
                  : '${session.userToken.substring(0, 32)}…',
            ),
          ),
          const Divider(height: 32),
          const Text(
            'Connections',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          ListTile(
            title: const Text('MQTT'),
            subtitle: Text(
              c.sdk.mqtt.hasConnected ? 'Connected' : 'Disconnected',
            ),
          ),
          ListTile(
            title: const Text('Reconnect MQTT'),
            subtitle: const Text('disconnect then connect (test)'),
            onTap: () async {
              try {
                await c.sdk.disconnectMqtt();
                await c.sdk.connectMqtt();
                c.appendExampleLog(
                  'MQTT reconnect done connected=${c.sdk.mqtt.hasConnected}',
                );
                if (context.mounted) {
                  setState(() {});
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('$e')));
                }
              }
            },
          ),
          ListTile(
            title: const Text('Detach meeting router'),
            subtitle: const Text('Stops MQTT → router pipeline'),
            onTap: () {
              c.sdk.detachMeetingRouter();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Router detached')),
              );
            },
          ),
          ListTile(
            title: const Text('Attach meeting router'),
            onTap: () {
              c.sdk.attachMeetingRouterToMqtt();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Router attached')),
              );
            },
          ),
          const Divider(height: 32),
          const Text(
            'Native / CallKit simulations',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          ListTile(
            title: const Text('Simulate incoming call'),
            onTap: () async {
              await c.sdk.native.reportIncomingCall(
                callerName: 'Test caller',
                callId: 'sim-${DateTime.now().millisecondsSinceEpoch}',
                hasVideo: false,
                metadata: <String, dynamic>{'source': 'settings_simulation'},
              );
            },
          ),
          ListTile(
            title: const Text('Outgoing call (native only)'),
            subtitle: const Text('No REST — local CallKit UI test'),
            onTap: () async {
              await c.sdk.native.startOutgoingCall(
                callee: const IsometrikCallDisplayUser(
                  userId: 'local',
                  userName: 'Local test',
                ),
                callId: 'local-${DateTime.now().millisecondsSinceEpoch}',
                hasVideo: true,
                metadata: <String, dynamic>{'source': 'settings'},
              );
            },
          ),
          const Divider(height: 32),
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'API HTTP trace',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
              TextButton(
                onPressed: c.clearApiLogs,
                child: const Text('Clear'),
              ),
            ],
          ),
          const Text(
            'Mirrors [IsometrikHttpClient] debug lines (also printed to debug console).',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 280),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.black12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: c.apiLogBuffer.isEmpty
                ? const Center(child: Text('No API logs yet'))
                : ListView.builder(
                    reverse: false,
                    itemCount: c.apiLogBuffer.length,
                    itemBuilder: (BuildContext context, int i) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: SelectableText(
                          c.apiLogBuffer[i],
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
