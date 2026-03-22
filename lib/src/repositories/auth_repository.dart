import '../api/isometrik_api_error.dart';
import '../api/isometrik_endpoints.dart';
import '../api/isometrik_http_client.dart';
import '../models/models.dart';

/// Mirrors Swift `ISMCallMeetingViewModel.fetchUsers` + authenticate endpoint.
class IsometrikAuthRepository {
  IsometrikAuthRepository(this._client);

  final IsometrikHttpClient _client;

  Future<IsometrikResult<IsometrikAuthSession>> authenticate({
    required String email,
    required String password,
  }) async {
    final body = IsometrikAuthenticateRequest(
      userIdentifier: email,
      password: password,
    );
    return _client.sendJson<IsometrikAuthSession>(
      const IsometrikEndpoint(
        path: IsometrikApiPaths.authenticate,
        method: IsometrikHttpMethod.post,
      ),
      body: body.toJson(),
      decode: IsometrikAuthSession.fromJson,
      useMeetingHeaders: false,
    );
  }

  Future<IsometrikResult<List<IsometrikDirectoryUser>>> fetchUsers({
    required String searchTag,
    int skip = 0,
    int limit = 10,
  }) async {
    final r = await _client.sendJson<IsometrikDirectoryUsers>(
      IsometrikEndpoint(
        path: IsometrikApiPaths.users,
        method: IsometrikHttpMethod.get,
        query: <String, String>{
          'skip': '$skip',
          'limit': '$limit',
          if (searchTag.isNotEmpty) 'searchTag': searchTag,
        },
      ),
      decode: IsometrikDirectoryUsers.fromJson,
      useMeetingHeaders: false,
    );
    return r.when(
      success: (data) => IsometrikSuccess(data.users),
      failure: IsometrikFailure.new,
    );
  }
}
