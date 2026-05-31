import 'package:shared_preferences/shared_preferences.dart';

/// Persists chat list UI filter preferences.
abstract class ChatListPreferencesStore {
  Future<bool> getShowOnlineOnly();

  Future<void> setShowOnlineOnly(bool enabled);

  Future<bool> getShowClosedChats();

  Future<void> setShowClosedChats(bool enabled);

  Future<bool> getShowFriendsOnly();

  Future<void> setShowFriendsOnly(bool enabled);

  bool get currentShowOnlineOnly;

  bool get currentShowClosedChats;

  bool get currentShowFriendsOnly;
}

class SharedPrefsChatListPreferencesStore implements ChatListPreferencesStore {
  static const _showOnlineOnlyKey = 'airgrid_chat_show_online_only';
  static const _showClosedChatsKey = 'airgrid_chat_show_closed_chats';
  static const _showFriendsOnlyKey = 'airgrid_chat_show_friends_only';

  final SharedPreferences _prefs;
  bool _showOnlineOnly;
  bool _showClosedChats;
  bool _showFriendsOnly;

  SharedPrefsChatListPreferencesStore._(this._prefs)
    : _showOnlineOnly = _prefs.getBool(_showOnlineOnlyKey) ?? false,
      _showClosedChats = _prefs.getBool(_showClosedChatsKey) ?? false,
      _showFriendsOnly = _prefs.getBool(_showFriendsOnlyKey) ?? false;

  static Future<SharedPrefsChatListPreferencesStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SharedPrefsChatListPreferencesStore._(prefs);
  }

  @override
  Future<bool> getShowOnlineOnly() async => _showOnlineOnly;

  @override
  Future<void> setShowOnlineOnly(bool enabled) async {
    _showOnlineOnly = enabled;
    await _prefs.setBool(_showOnlineOnlyKey, enabled);
  }

  @override
  Future<bool> getShowClosedChats() async => _showClosedChats;

  @override
  Future<void> setShowClosedChats(bool enabled) async {
    _showClosedChats = enabled;
    await _prefs.setBool(_showClosedChatsKey, enabled);
  }

  @override
  Future<bool> getShowFriendsOnly() async => _showFriendsOnly;

  @override
  Future<void> setShowFriendsOnly(bool enabled) async {
    _showFriendsOnly = enabled;
    await _prefs.setBool(_showFriendsOnlyKey, enabled);
  }

  @override
  bool get currentShowOnlineOnly => _showOnlineOnly;

  @override
  bool get currentShowClosedChats => _showClosedChats;

  @override
  bool get currentShowFriendsOnly => _showFriendsOnly;
}

class InMemoryChatListPreferencesStore implements ChatListPreferencesStore {
  bool _showOnlineOnly;
  bool _showClosedChats;
  bool _showFriendsOnly;

  InMemoryChatListPreferencesStore({
    bool initialShowOnlineOnly = false,
    bool initialShowClosedChats = false,
    bool initialShowFriendsOnly = false,
  }) : _showOnlineOnly = initialShowOnlineOnly,
       _showClosedChats = initialShowClosedChats,
       _showFriendsOnly = initialShowFriendsOnly;

  @override
  Future<bool> getShowOnlineOnly() async => _showOnlineOnly;

  @override
  Future<void> setShowOnlineOnly(bool enabled) async {
    _showOnlineOnly = enabled;
  }

  @override
  Future<bool> getShowClosedChats() async => _showClosedChats;

  @override
  Future<void> setShowClosedChats(bool enabled) async {
    _showClosedChats = enabled;
  }

  @override
  Future<bool> getShowFriendsOnly() async => _showFriendsOnly;

  @override
  Future<void> setShowFriendsOnly(bool enabled) async {
    _showFriendsOnly = enabled;
  }

  @override
  bool get currentShowOnlineOnly => _showOnlineOnly;

  @override
  bool get currentShowClosedChats => _showClosedChats;

  @override
  bool get currentShowFriendsOnly => _showFriendsOnly;
}
