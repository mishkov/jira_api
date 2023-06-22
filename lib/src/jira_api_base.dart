import 'dart:developer';

import 'package:atlassian_apis/jira_platform.dart';

class JiraStats {
  final String user;
  final String apiToken;

  ApiClient? _apiClient;
  JiraPlatformApi? _jira;

  JiraStats({required this.user, required this.apiToken});

  Future<void> initialize() async {
    // Create an authenticated http client.
    _apiClient = ApiClient.basicAuthentication(
      Uri.https('asandsb.atlassian.net', ''),
      user: user,
      apiToken: apiToken,
    );

    // Create the API wrapper from the http client
    _jira = JiraPlatformApi(_apiClient!);

    // Communicate with the APIs..
    await _jira!.projects.searchProjects();
  }

  Future<void> dispose() async {
    _apiClient?.close();
    _apiClient = null;

    _jira?.close();
    _jira = null;
  }

  Future<double?> getTotalEstimationFor({required String label}) async {
    if (_jira == null) {
      throw JiraNotInitializedException();
    }

    double total = 0.0;
    int startCountAt = 0;
    int? restIssues;
    do {
      const storyPointEstimateField = 'customfield_10016';
      final searchResults = await _jira!.issueSearch.searchForIssuesUsingJql(
        jql: 'project = "AS" AND labels in ("$label")',
        fields: [storyPointEstimateField],
        startAt: startCountAt,
      );

      for (final issue in searchResults.issues) {
        if (issue.fields == null) {
          // TODO: instead of logging create separate structure that will
          // contain result and ignored issues with specified reasons
          log('issue ${issue.key} is ignored because hasn\'t required fields');
          
          continue;
        }

        final storyPointEstimate = issue.fields![storyPointEstimateField];

        if (storyPointEstimate is! double) {
          // TODO: instead of logging create separate structure that will
          // contain result and ignored issues with specified reasons
          log('issue ${issue.key} is ignored because storyPointEstimate field is not double or is null');
          
          continue;
        }

        total += storyPointEstimate;
      }

      if (searchResults.total == null) {
        // TODO: throw Exception instead;
        return null;
      }

      if (searchResults.maxResults == null) {
        // TODO: throw Exception instead;
        return null;
      }
      restIssues ??= searchResults.total!;
      restIssues -= searchResults.maxResults!;

      startCountAt + searchResults.maxResults!;
    } while (restIssues > 0);

    return total;
  }
}

class JiraNotInitializedException implements Exception {}
