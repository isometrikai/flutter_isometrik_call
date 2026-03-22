import 'dart:async';

import 'package:flutter/material.dart';
import 'package:isometrik_flutter_call/isometrik_flutter_call.dart';
import 'package:provider/provider.dart';

import '../app/example_app_controller.dart';

/// Mirrors [Example/ISMCallSearchUsersViewController.swift]: search by name, multi-select, Done.
class SearchUsersPage extends StatefulWidget {
  const SearchUsersPage({super.key});

  @override
  State<SearchUsersPage> createState() => _SearchUsersPageState();
}

class _SearchUsersPageState extends State<SearchUsersPage> {
  /// Identity by [IsometrikDirectoryUser.userId] (no custom == on model).
  final List<IsometrikDirectoryUser> _selected = <IsometrikDirectoryUser>[];
  List<IsometrikDirectoryUser> _results = <IsometrikDirectoryUser>[];
  bool _loading = false;
  Timer? _debounce;

  bool _isSelected(IsometrikDirectoryUser u) =>
      _selected.any((IsometrikDirectoryUser x) => x.userId == u.userId);

  void _toggle(IsometrikDirectoryUser u) {
    setState(() {
      final int i = _selected.indexWhere(
        (IsometrikDirectoryUser x) => x.userId == u.userId,
      );
      if (i >= 0) {
        _selected.removeAt(i);
      } else {
        _selected.add(u);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _fetch(String q) async {
    setState(() {
      _loading = true;
    });
    final c = context.read<ExampleAppController>();
    final users = await c.searchUsers(q);
    if (!mounted) {
      return;
    }
    setState(() {
      _results = users;
      _loading = false;
    });
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _fetch(q));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch(''));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Search users')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search by name (Swift fetchUsers)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: _results.isEmpty && !_loading
                ? const Center(child: Text('No search results found.'))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (BuildContext context, int i) {
                      final u = _results[i];
                      final sel = _isSelected(u);
                      return ListTile(
                        title: Text(u.userName),
                        subtitle: Text(
                          u.userIdentifier,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: sel
                            ? const Icon(Icons.check_circle, color: Colors.green)
                            : const Icon(Icons.circle_outlined),
                        onTap: () => _toggle(u),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(
                      context,
                    ).pop<List<IsometrikDirectoryUser>>(List<IsometrikDirectoryUser>.from(_selected));
                  },
                  child: const Text('Done'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
