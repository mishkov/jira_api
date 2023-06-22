import 'dart:convert';
import 'dart:developer';

import 'package:atlassian_apis/jira_platform.dart';
import 'package:collection/collection.dart';

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

  Future<EstimationResults> getTotalEstimationFor(
      {required String label}) async {
    if (_jira == null) {
      throw JiraNotInitializedException();
    }

    List<IgnoredIssue> ignoredIssues = [];
    Map<IssueStatus, double> groupedEstimation = {};

    int startCountAt = 0;
    int? restIssues;
    do {
      const storyPointEstimateField = 'customfield_10016';
      const statusField = 'status';
      final searchResults = await _jira!.issueSearch.searchForIssuesUsingJql(
        jql: 'project = "AS" AND labels in ("$label")',
        fields: [
          storyPointEstimateField,
          statusField,
        ],
        startAt: startCountAt,
      );

      for (final issue in searchResults.issues) {
        if (issue.fields == null) {
          ignoredIssues.add(IgnoredIssue(
            issue.key ?? issue.id,
            reason: 'hasn\'t required fields',
          ));

          continue;
        }

        final storyPointEstimate = issue.fields![storyPointEstimateField];

        if (storyPointEstimate is! double) {
          ignoredIssues.add(IgnoredIssue(
            issue.key ?? issue.id,
            reason: 'storyPointEstimate field is not double or is null',
          ));

          continue;
        }

        final rawStatus = issue.fields![statusField];

        if (rawStatus is! Map<String, dynamic>) {
          ignoredIssues.add(IgnoredIssue(
            issue.key ?? issue.id,
            reason: 'status field is not Map or is null',
          ));

          continue;
        }

        final status = IssueStatus.fromMap(rawStatus);
        if (groupedEstimation.containsKey(status)) {
          groupedEstimation[status] =
              groupedEstimation[status]! + storyPointEstimate;
        } else {
          groupedEstimation.addAll({status: storyPointEstimate});
        }
      }

      if (searchResults.total == null) {
        throw SearchResultHasNotEnoughtInfo();
      }

      if (searchResults.maxResults == null) {
        throw SearchResultHasNotEnoughtInfo();
      }

      restIssues ??= searchResults.total!;
      restIssues -= searchResults.maxResults!;

      startCountAt += searchResults.maxResults!;
    } while (restIssues > 0);

    return EstimationResults(
      ignoredIssues: ignoredIssues,
      groupedEstimation: groupedEstimation,
    );
  }
}

class JiraNotInitializedException implements Exception {}

class SearchResultHasNotEnoughtInfo implements Exception {}

class EstimationResults {
  List<IgnoredIssue> ignoredIssues;
  Map<IssueStatus, double> groupedEstimation;

  EstimationResults({
    required this.ignoredIssues,
    required this.groupedEstimation,
  });
}

class IgnoredIssue {
  final String? key;
  final String reason;

  IgnoredIssue(
    this.key, {
    required this.reason,
  });
}

class IssueStatus {
  final String id;
  final String name;

  IssueStatus({
    required this.id,
    required this.name,
  });

  factory IssueStatus.fromMap(Map<String, dynamic> map) {
    return IssueStatus(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
    );
  }

  factory IssueStatus.fromJson(String source) =>
      IssueStatus.fromMap(json.decode(source));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is IssueStatus && other.id == id && other.name == name;
  }

  @override
  int get hashCode => id.hashCode ^ name.hashCode;
}
