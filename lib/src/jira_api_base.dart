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

    List<Issue> estimatedIssues = [];
    List<IgnoredIssue> ignoredIssues = [];
    List<EstimatedGroup> groupedEstimation = [];

    int startCountAt = 0;
    int? restIssues;
    do {
      const storyPointEstimateField = 'customfield_10016';
      const statusField = 'status';
      const createDateField = 'created';
      final searchResults = await _jira!.issueSearch.searchForIssuesUsingJql(
        jql: 'project = "AS" AND labels in ("$label")',
        // fields: [
        //   storyPointEstimateField,
        //   statusField,
        //   createDateField,
        // ],
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

        estimatedIssues.add(Issue(
          issue.key,
          estimation: storyPointEstimate,
          creationDate: DateTime.tryParse(issue.fields![createDateField]),
          status: status,
        ));

        final group = groupedEstimation
            .singleWhere((e) => e.groupStatus == status, orElse: () {
          final newGroup = EstimatedGroup(groupStatus: status);
          groupedEstimation.add(newGroup);
          return newGroup;
        });
        group.estimation += storyPointEstimate;
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

    List<GroupedIssuesRecord> datedGroups = [];
    final now = DateTime.now();
    final currentDay = DateTime(now.year, now.month, now.day);
    for (int i = 0; i < 4; i++) {
      const weekLength = 7;
      datedGroups.add(GroupedIssuesRecord(
        date: currentDay.subtract(Duration(days: i * weekLength)),
        groupedEstimations: [],
      ));
    }

    // TODO: try to parse history here
    for (final issue in estimatedIssues) {
      final changelogs = await _jira!.issues
          .getChangeLogs(issueIdOrKey: issue.key!, maxResults: 1000);

      final List<Changelog> filteredChangelog =
          filterChangelogByStatusAndGroupByDate(changelogs);

      int i = 0;
      for (; i < datedGroups.length - 1; i++) {
        final groupDate = datedGroups[i].date;
        final previousGroupDate = datedGroups[i + 1].date;

        for (final changelog in filteredChangelog) {
          final statusChanges = changelog.items.where((element) {
            return element.field == 'status';
          });

          if (doesBelongToGroup(
              groupDate, previousGroupDate, changelog.created!)) {
            final status = IssueStatus.fromChangeDetails(statusChanges.single);

            final doesStatusAlreadyAdded = datedGroups[i]
                .groupedEstimations
                .any((element) => element.groupStatus == status);
            if (doesStatusAlreadyAdded) {
              final estimationGroup = datedGroups[i]
                  .groupedEstimations
                  .where((element) => element.groupStatus == status)
                  .single;

              estimationGroup.estimation =
                  estimationGroup.estimation + issue.estimation!;
            } else {
              datedGroups[i].groupedEstimations.add(EstimatedGroup(
                  groupStatus: status, estimation: issue.estimation!));
            }

            break;
          }
        }
      }
      final groupDate = datedGroups[i].date;

      // TODO: set default status
      if (issue.creationDate!.isBefore(groupDate) ||
          issue.creationDate!.isAtSameMomentAs(groupDate)) {
        IssueStatus? status;

        if (filteredChangelog.reversed.isEmpty) {
          status = issue.status!;
        } else {
          final firstChange =
              filteredChangelog.reversed.first.items.where((element) {
            return element.field == 'status';
          }).single;

          status = IssueStatus(
            id: firstChange.from!,
            name: firstChange.fromString!,
          );
        }

        final doesStatusAlreadyAdded = datedGroups[i]
            .groupedEstimations
            .any((element) => element.groupStatus == status);
        if (doesStatusAlreadyAdded) {
          final estimationGroup = datedGroups[i]
              .groupedEstimations
              .where((element) => element.groupStatus == status)
              .single;

          estimationGroup.estimation =
              estimationGroup.estimation + issue.estimation!;
        } else {
          datedGroups[i].groupedEstimations.add(EstimatedGroup(
              groupStatus: status, estimation: issue.estimation!));
        }
      }
    }

    return EstimationResults(
      ignoredIssues: ignoredIssues,
      groupedEstimationAtTheMoment: groupedEstimation,
      datedGroups: datedGroups,
    );
  }

  static bool doesBelongToGroup(DateTime previousDatedGroup, DateTime datedGroup,
      DateTime changeLogDate) {
    return (changeLogDate.isAfter(previousDatedGroup) &&
        (changeLogDate.isBefore(datedGroup) ||
            changeLogDate.isAtSameMomentAs(datedGroup)));
  }

  List<Changelog> filterChangelogByStatusAndGroupByDate(
      PageBeanChangelog changelogs) {
    List<Changelog> filteredChangelog = [];

    for (final changelog in changelogs.values.reversed) {
      final statusChanges = changelog.items.where((element) {
        return element.field == 'status';
      });

      if (statusChanges.isEmpty) {
        continue;
      }

      if (statusChanges.length > 1) {
        log('${changelog.id} ignored because has more than 1 status changes');
        continue;
      }

      final dateTime = changelog.created!;
      final date = DateTime(
        dateTime.year,
        dateTime.month,
        dateTime.day,
      );

      if (filteredChangelog.any((element) => element.created == date)) {
        continue;
      }

      filteredChangelog.add(changelog.copyWith(created: date));
    }

    return filteredChangelog;
  }
}

class JiraNotInitializedException implements Exception {}

class SearchResultHasNotEnoughtInfo implements Exception {}

class EstimationResults {
  List<IgnoredIssue> ignoredIssues;
  List<EstimatedGroup> groupedEstimationAtTheMoment;
  List<GroupedIssuesRecord> datedGroups;

  EstimationResults({
    required this.ignoredIssues,
    required this.groupedEstimationAtTheMoment,
    required this.datedGroups,
  });
}

class Issue {
  final String? key;
  final double? estimation;
  final DateTime? creationDate;
  final IssueStatus? status;

  Issue(
    this.key, {
    this.estimation,
    this.creationDate,
    this.status,
  });
}

class IgnoredIssue extends Issue {
  final String reason;

  IgnoredIssue(
    super.key, {
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

  factory IssueStatus.fromChangeDetails(ChangeDetails details) {
    return IssueStatus(
      id: details.to ?? '',
      name: details.toString$ ?? '',
    );
  }

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

class EstimatedGroup {
  final IssueStatus groupStatus;
  double estimation;

  EstimatedGroup({
    required this.groupStatus,
    this.estimation = 0.0,
  });
}

class GroupedIssuesRecord {
  final DateTime date;
  final List<EstimatedGroup> groupedEstimations;

  GroupedIssuesRecord({
    required this.date,
    required this.groupedEstimations,
  });
}
