import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mrdb/main.dart';
import 'package:mrdb/services/telegram_stream_service.dart';

class BotManagerPage extends StatefulWidget {
  const BotManagerPage({super.key});

  @override
  State<BotManagerPage> createState() => _BotManagerPageState();
}

class _BotManagerPageState extends State<BotManagerPage>
    with SingleTickerProviderStateMixin {
  static const Color _kBgColor = Color(0xFF0D0D14);
  static const Color _kCardBg = Color(0xFF1A1E2B);
  static const Color _kInputBg = Color(0xFF1E2434);
  static const Color _kCardBorder = Color(0xFF313950);
  static const Color _kAccent = Color(0xFF00E5A0);
  static const Color _kTextPrimary = Color(0xFFF3F6FA);
  static const Color _kTextSecondary = Color(0xFFA3AEBF);

  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _broadcastController = TextEditingController();
  final ScrollController _usersScrollController = ScrollController();
  Timer? _searchDebounce;
  Timer? _broadcastPollTimer;

  BotAdminStats? _stats;
  bool _loadingStats = true;

  List<BotUserItem> _users = [];
  bool _loadingUsers = true;
  bool _loadingMoreUsers = false;
  bool _hasMoreUsers = true;
  int _usersOffset = 0;
  String? _usersError;

  bool _sendingBroadcast = false;
  BotBroadcastResult? _lastBroadcast;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _usersScrollController.addListener(_onUsersScroll);
    _loadAll();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _broadcastPollTimer?.cancel();
    _tabController.dispose();
    _searchController.dispose();
    _broadcastController.dispose();
    _usersScrollController.removeListener(_onUsersScroll);
    _usersScrollController.dispose();
    super.dispose();
  }

  void _onUsersScroll() {
    if (_loadingMoreUsers || !_hasMoreUsers || _loadingUsers) return;
    if (_usersScrollController.position.pixels >=
        _usersScrollController.position.maxScrollExtent - 200) {
      _loadMoreUsers();
    }
  }

  Future<void> _loadAll() async {
    await Future.wait([_loadStats(), _loadUsers(reset: true)]);
  }

  Future<void> _loadStats() async {
    setState(() => _loadingStats = true);
    final stats = await TelegramStreamService.instance.fetchBotAdminStats();
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _loadingStats = false;
    });
  }

  Future<void> _loadUsers({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loadingUsers = true;
        _usersError = null;
        _usersOffset = 0;
        _hasMoreUsers = true;
      });
    }
    final res = await TelegramStreamService.instance.fetchBotUsers(
      query: _searchController.text.trim(),
      limit: 30,
      offset: 0,
    );
    if (!mounted) return;
    setState(() {
      _users = res.users;
      _hasMoreUsers = res.hasMore;
      _usersOffset = res.users.length;
      _usersError = res.errorMessage;
      _loadingUsers = false;
    });
  }

  Future<void> _loadMoreUsers() async {
    setState(() => _loadingMoreUsers = true);
    final res = await TelegramStreamService.instance.fetchBotUsers(
      query: _searchController.text.trim(),
      limit: 30,
      offset: _usersOffset,
    );
    if (!mounted) return;
    setState(() {
      _users.addAll(res.users);
      _hasMoreUsers = res.hasMore;
      _usersOffset += res.users.length;
      _loadingMoreUsers = false;
    });
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      _loadUsers(reset: true);
    });
  }

  Future<void> _toggleBan(BotUserItem user) async {
    final nextBan = !user.isBanned;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCardBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: _kCardBorder),
        ),
        title: Text(
          nextBan ? 'Ban Bot User?' : 'Unban Bot User?',
          style: const TextStyle(
            color: _kTextPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          nextBan
              ? 'User ${user.id} will be blocked from using the bot.'
              : 'User ${user.id} will regain access to the bot.',
          style: const TextStyle(color: _kTextSecondary, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: _kTextSecondary),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: nextBan ? const Color(0xFFE5534B) : _kAccent,
              foregroundColor: nextBan ? Colors.white : Colors.black,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              nextBan ? 'Ban' : 'Unban',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final ok = await TelegramStreamService.instance.setBotUserBanned(
      user.id,
      ban: nextBan,
    );
    if (!mounted) return;
    if (ok) {
      setState(() {
        final idx = _users.indexWhere((u) => u.id == user.id);
        if (idx != -1) _users[idx] = user.copyWith(isBanned: nextBan);
      });
      _loadStats();
      showScaffoldMsg(
        context,
        txt: nextBan ? 'User ${user.id} banned' : 'User ${user.id} unbanned',
      );
    } else {
      showScaffoldMsg(context, txt: 'Failed to update ban status');
    }
  }

  Future<void> _sendBroadcast() async {
    final text = _broadcastController.text.trim();
    if (text.isEmpty) {
      showScaffoldMsg(context, txt: 'Enter a broadcast message');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCardBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: _kCardBorder),
        ),
        title: const Text(
          'Send Broadcast?',
          style: TextStyle(
            color: _kTextPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          'This will send your message to ${_stats?.totalUsers ?? 'all'} bot users.',
          style: const TextStyle(color: _kTextSecondary, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: _kTextSecondary),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kAccent,
              foregroundColor: Colors.black,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Send Now',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    FocusScope.of(context).unfocus();
    _broadcastPollTimer?.cancel();
    setState(() => _sendingBroadcast = true);
    final result = await TelegramStreamService.instance.sendBotBroadcast(text);
    if (!mounted) return;
    setState(() {
      _sendingBroadcast = false;
      _lastBroadcast = result;
    });
    if (result.ok) {
      _broadcastController.clear();
      if (!result.done && result.jobId != null && result.baseUrl != null) {
        showScaffoldMsg(
          context,
          txt: 'Broadcast started for ${result.total} users',
        );
        _broadcastPollTimer = Timer.periodic(
          const Duration(seconds: 1),
          (t) async {
            final status = await TelegramStreamService.instance
                .fetchBroadcastStatus(result.baseUrl!, result.jobId!);
            if (!mounted) {
              t.cancel();
              return;
            }
            if (status != null) {
              setState(() => _lastBroadcast = status);
              if (status.done) {
                t.cancel();
                showScaffoldMsg(
                  context,
                  txt: 'Broadcast finished: ${status.sent}/${status.total} sent',
                );
              }
            }
          },
        );
      } else {
        showScaffoldMsg(
          context,
          txt: 'Broadcast sent: ${result.sent}/${result.total}',
        );
      }
    } else {
      showScaffoldMsg(context, txt: result.error ?? 'Broadcast failed');
    }
  }

  Widget _buildStatTile(String label, String value, Color accent) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: _kInputBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kCardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: accent,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: _kTextSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsHeader() {
    if (_loadingStats) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: LinearProgressIndicator(
          minHeight: 2,
          color: _kAccent,
          backgroundColor: _kCardBg,
        ),
      );
    }
    final s = _stats;
    if (s == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _kCardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _kCardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.smart_toy_rounded, color: _kAccent, size: 17),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    s.telegramBot.isNotEmpty ? s.telegramBot : 'Bot Server',
                    style: const TextStyle(
                      color: _kTextPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  'Uptime ${s.uptime}',
                  style: const TextStyle(
                    color: _kTextSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _buildStatTile('Users', '${s.totalUsers}', _kAccent),
                const SizedBox(width: 8),
                _buildStatTile('Banned', '${s.bannedUsers}', const Color(0xFFFF7B72)),
                const SizedBox(width: 8),
                _buildStatTile('Videos', '${s.totalVideos}', const Color(0xFF54C5F8)),
                const SizedBox(width: 8),
                _buildStatTile('Clients', '${s.connectedBots}', const Color(0xFFF5C451)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsersTab() {
    return RefreshIndicator(
      color: _kAccent,
      backgroundColor: _kCardBg,
      onRefresh: _loadAll,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: _kInputBg,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: _kCardBorder),
              ),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: _kTextPrimary, fontSize: 13.5),
                onChanged: _onSearchChanged,
                decoration: const InputDecoration(
                  hintText: 'Search by name, @username, or ID...',
                  hintStyle: TextStyle(color: _kTextSecondary),
                  border: InputBorder.none,
                  icon: Icon(Icons.search_rounded, color: _kAccent, size: 19),
                ),
              ),
            ),
          ),
          Expanded(
            child: _loadingUsers
                ? const Center(child: CircularProgressIndicator(color: _kAccent))
                : _usersError != null
                ? Center(
                    child: Text(
                      _usersError!,
                      style: const TextStyle(color: _kTextSecondary),
                    ),
                  )
                : _users.isEmpty
                ? const Center(
                    child: Text(
                      'No bot users found.',
                      style: TextStyle(color: _kTextSecondary),
                    ),
                  )
                : ListView.separated(
                    controller: _usersScrollController,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                    itemCount: _users.length + (_loadingMoreUsers ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, idx) {
                      if (idx >= _users.length) {
                        return const Padding(
                          padding: EdgeInsets.all(12),
                          child: Center(
                            child: CircularProgressIndicator(color: _kAccent),
                          ),
                        );
                      }
                      final u = _users[idx];
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: _kCardBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: u.isBanned
                                ? const Color(0xFFE5534B).withValues(alpha: 0.45)
                                : _kCardBorder,
                          ),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 18,
                              backgroundColor: (u.isBanned
                                      ? const Color(0xFFE5534B)
                                      : _kAccent)
                                  .withValues(alpha: 0.16),
                              child: Icon(
                                u.isBanned
                                    ? Icons.block_rounded
                                    : Icons.person_rounded,
                                color: u.isBanned
                                    ? const Color(0xFFFF7B72)
                                    : _kAccent,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  GestureDetector(
                                    onLongPress: () {
                                      final copyText = u.username.isNotEmpty
                                          ? '@${u.username}'
                                          : '${u.id}';
                                      Clipboard.setData(
                                        ClipboardData(text: copyText),
                                      );
                                      showScaffoldMsg(
                                        context,
                                        txt: 'Copied $copyText',
                                      );
                                    },
                                    child: Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            u.name.isNotEmpty
                                                ? u.name
                                                : 'User ${u.id}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: _kTextPrimary,
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        if (u.username.isNotEmpty) ...[
                                          const SizedBox(width: 6),
                                          Text(
                                            '@${u.username}',
                                            style: const TextStyle(
                                              color: _kAccent,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    u.joinDate.isNotEmpty
                                        ? 'ID: ${u.id}  •  Joined ${u.joinDate}'
                                        : 'ID: ${u.id}',
                                    style: const TextStyle(
                                      color: _kTextSecondary,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: () => _toggleBan(u),
                              style: TextButton.styleFrom(
                                foregroundColor: u.isBanned
                                    ? _kAccent
                                    : const Color(0xFFFF7B72),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                              ),
                              child: Text(
                                u.isBanned ? 'Unban' : 'Ban',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildBroadcastTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _kCardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _kCardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Broadcast to All Bot Users',
                  style: TextStyle(
                    color: _kTextPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Sends a Telegram message from @FileToSpeedLink_Bot to every registered bot user.',
                  style: TextStyle(color: _kTextSecondary, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _kInputBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _kCardBorder),
                  ),
                  child: TextField(
                    controller: _broadcastController,
                    maxLines: 5,
                    style: const TextStyle(
                      color: _kTextPrimary,
                      fontSize: 13.5,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Write your announcement...',
                      hintStyle: TextStyle(color: _kTextSecondary),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _sendingBroadcast ? null : _sendBroadcast,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kAccent,
                      foregroundColor: Colors.black,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: _sendingBroadcast
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Icon(Icons.campaign_rounded, size: 19),
                    label: Text(
                      _sendingBroadcast ? 'Sending...' : 'Send Broadcast',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_lastBroadcast != null && _lastBroadcast!.ok) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _kCardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _kAccent.withValues(alpha: 0.4)),
              ),
              child: Text(
                _lastBroadcast!.done
                    ? 'Broadcast complete: ${_lastBroadcast!.sent} sent, ${_lastBroadcast!.failed} failed (out of ${_lastBroadcast!.total} users).'
                    : 'Sending broadcast... ${_lastBroadcast!.sent}/${_lastBroadcast!.total} sent',
                style: const TextStyle(
                  color: _kAccent,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBgColor,
      appBar: AppBar(
        backgroundColor: _kBgColor,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: _kTextPrimary),
        title: const Text(
          'Bot Manager',
          style: TextStyle(
            color: _kTextPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: _kTextPrimary),
            onPressed: _loadAll,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatsHeader(),
          TabBar(
            controller: _tabController,
            indicatorColor: _kAccent,
            labelColor: _kAccent,
            unselectedLabelColor: _kTextSecondary,
            dividerColor: _kCardBorder,
            tabs: const [
              Tab(text: 'Users'),
              Tab(text: 'Broadcast'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [_buildUsersTab(), _buildBroadcastTab()],
            ),
          ),
        ],
      ),
    );
  }
}
