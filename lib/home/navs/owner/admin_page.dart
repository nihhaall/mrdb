import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mrdb/home/navs/owner/bot_manager_page.dart';
import 'package:mrdb/home/navs/owner/manage_clients_page.dart';
import 'package:mrdb/home/navs/owner/mongodb_movies_page.dart';
import 'package:mrdb/widgets/movie_collection_sheets.dart';

/// Owner-only hub grouping client management and Telegram bot administration.
class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  static const Color _kBgColor = Color(0xFF000000);
  static const Color _kCardBg = Color(0xFF14161F);
  static const Color _kCardBorder = Color(0xFF222536);
  static const Color _kAccent = Color(0xFF00E5A0);
  static const Color _kTextPrimary = Color(0xFFF5F7FA);
  static const Color _kTextSecondary = Color(0xFF8E97AB);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBgColor,
      appBar: AppBar(
        backgroundColor: _kBgColor,
        elevation: 0,
        iconTheme: const IconThemeData(color: _kTextPrimary),
        title: const Row(
          children: [
            Text(
              'Admin',
              style: TextStyle(
                color: _kTextPrimary,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(width: 8),
            Icon(
              Icons.admin_panel_settings_rounded,
              color: Colors.amber,
              size: 19,
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _kCardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _kCardBorder),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.shield_rounded,
                  color: Colors.amber,
                  size: 20,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Owner tools for managing registered app clients and controlling the FileToLink bot.',
                    style: TextStyle(
                      color: _kTextSecondary,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildAdminTile(
            context: context,
            icon: Icons.people_alt_rounded,
            title: 'Manage Clients',
            subtitle: 'View all registered devices & their liked movies',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ManageClientsPage()),
            ),
          ),
          const SizedBox(height: 12),
          _buildAdminTile(
            context: context,
            icon: Icons.smart_toy_rounded,
            title: 'Bot Manager',
            subtitle: 'Track bot users, ban/unban & send broadcasts',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BotManagerPage()),
            ),
          ),
          const SizedBox(height: 12),
          _buildAdminTile(
            context: context,
            icon: Icons.storage_rounded,
            title: 'MongoDB Movies',
            subtitle: 'List all saved movies in MongoDB, delete or clear DB',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MongoDbMoviesPage()),
            ),
          ),
          const SizedBox(height: 12),
          _buildAdminTile(
            context: context,
            icon: Icons.key_rounded,
            title: 'Gemini AI Settings',
            subtitle: 'Set Gemini API key & AI filename prompt preset',
            onTap: () => showAiSettingsDialog(context),
          ),
        ],
      ),
    );
  }

  Widget _buildAdminTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
          color: _kCardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _kAccent.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: _kAccent.withValues(alpha: 0.08),
              blurRadius: 14,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: _kAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: _kAccent, size: 21),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: _kTextPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: _kTextSecondary,
                      fontSize: 11.8,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              color: _kAccent,
              size: 14,
            ),
          ],
        ),
      ),
    );
  }
}
