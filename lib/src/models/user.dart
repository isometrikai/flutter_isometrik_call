/// Search / directory user — mirrors `ISMCallUser`.
class IsometrikDirectoryUser {
  const IsometrikDirectoryUser({
    required this.userProfileImageUrl,
    required this.userName,
    required this.userIdentifier,
    required this.userId,
    required this.updatedAt,
    required this.notification,
    required this.createdAt,
  });

  factory IsometrikDirectoryUser.fromJson(Map<String, dynamic> json) {
    return IsometrikDirectoryUser(
      userProfileImageUrl: json['userProfileImageUrl'] as String? ?? '',
      userName: json['userName'] as String? ?? '',
      userIdentifier: json['userIdentifier'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      updatedAt: json['updatedAt'] as int? ?? 0,
      notification: json['notification'] as bool? ?? false,
      createdAt: json['createdAt'] as int? ?? 0,
    );
  }

  final String userProfileImageUrl;
  final String userName;
  final String userIdentifier;
  final String userId;
  final int updatedAt;
  final bool notification;
  final int createdAt;
}

class IsometrikDirectoryUsers {
  const IsometrikDirectoryUsers({required this.users, required this.msg});

  factory IsometrikDirectoryUsers.fromJson(Map<String, dynamic> json) {
    final list = json['users'] as List<dynamic>? ?? [];
    return IsometrikDirectoryUsers(
      users: list
          .map(
            (e) => IsometrikDirectoryUser.fromJson(e as Map<String, dynamic>),
          )
          .toList(),
      msg: json['msg'] as String? ?? '',
    );
  }

  final List<IsometrikDirectoryUser> users;
  final String msg;
}

/// Meeting member — mirrors `ISMCallMember`.
class IsometrikCallMember {
  IsometrikCallMember({
    this.memberName,
    this.memberIdentifier,
    this.memberId,
    this.isPublishing,
    this.isAdmin,
    this.memberProfileImageUrl,
  });

  final String? memberName;
  final String? memberIdentifier;
  final String? memberId;
  final bool? isPublishing;
  final bool? isAdmin;
  final String? memberProfileImageUrl;

  factory IsometrikCallMember.fromJson(Map<String, dynamic> json) {
    return IsometrikCallMember(
      memberName: json['memberName'] as String?,
      memberIdentifier: json['memberIdentifier'] as String?,
      memberId: json['memberId'] as String?,
      isPublishing: json['isPublishing'] as bool?,
      isAdmin: json['isAdmin'] as bool?,
      memberProfileImageUrl: json['memberProfileImageUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (memberName != null) 'memberName': memberName,
    if (memberIdentifier != null) 'memberIdentifier': memberIdentifier,
    if (memberId != null) 'memberId': memberId,
    if (isPublishing != null) 'isPublishing': isPublishing,
    if (isAdmin != null) 'isAdmin': isAdmin,
    if (memberProfileImageUrl != null)
      'memberProfileImageUrl': memberProfileImageUrl,
  };
}

/// Auth response — mirrors `ISMCallAuth`.
class IsometrikAuthSession {
  const IsometrikAuthSession({
    required this.userToken,
    required this.userId,
    required this.msg,
  });

  factory IsometrikAuthSession.fromJson(Map<String, dynamic> json) {
    return IsometrikAuthSession(
      userToken: json['userToken'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      msg: json['msg'] as String? ?? '',
    );
  }

  final String userToken;
  final String userId;
  final String msg;
}

/// PATCH user ack — mirrors `ISMUpdateUser`.
class IsometrikUpdateUserAck {
  const IsometrikUpdateUserAck({this.msg});

  factory IsometrikUpdateUserAck.fromJson(Map<String, dynamic> json) {
    return IsometrikUpdateUserAck(msg: json['msg'] as String?);
  }

  final String? msg;
}
