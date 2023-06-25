import 'dart:convert';
import 'dart:developer';

import 'package:atlassian_apis/jira_platform.dart';

enum SamplingFrequency { eachWeek, eachDay }

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

    try {
      final currentUser = await _jira!.myself.getCurrentUser();
      currentUser.accountId;
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        throw UnauthorizedException();
      }

      return;
    }

    // Communicate with the APIs..
    await _jira!.projects.searchProjects();
  }

  Future<void> dispose() async {
    _apiClient?.close();
    _apiClient = null;

    _jira?.close();
    _jira = null;
  }

  Future<List<String>> getLabels() async {
    if (_jira == null) {
      throw JiraNotInitializedException();
    }

    final page = await _jira!.labels.getAllLabels(maxResults: 100);
    return page.values;
  }

  Future<List<String>> validateJql(String jql) async {
    if (_jira == null) {
      throw JiraNotInitializedException();
    }

    final parsedJql = await _jira!.jql
        .parseJqlQueries(body: JqlQueriesToParse(queries: [jql]));

    return parsedJql.queries.single.errors;
  }

  Future<EstimationResults> getTotalEstimationByJql(
    String jql, {
    int weeksAgoCount = 4,
    SamplingFrequency frequency = SamplingFrequency.eachWeek,
  }) async {
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
        jql: jql,
        fields: [
          storyPointEstimateField,
          statusField,
          createDateField,
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
    final int periodLength;
    final int periodsAgo;
    if (frequency == SamplingFrequency.eachDay) {
      periodLength = 1;
      periodsAgo = weeksAgoCount * 7;
    } else {
      periodLength = 7;
      periodsAgo = weeksAgoCount;
    }
    for (int i = 0; i < periodsAgo; i++) {
      datedGroups.add(GroupedIssuesRecord(
        date: currentDay.subtract(Duration(days: i * periodLength)),
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

        IssueStatus? status;
        for (final changelog in filteredChangelog) {
          if (doesBelongToGroup(
              previousGroupDate, groupDate, changelog.created!)) {
            final statusChange = changelog.items.single;
            status = IssueStatus.fromChangeDetails(statusChange);

            break;
          }
        }

        if (status == null) {
          for (final changelog in filteredChangelog) {
            if (changelog.created!.isBefore(groupDate)) {
              status = IssueStatus.fromChangeDetails(changelog.items.single);

              break;
            }
          }
        }

        if (status == null) {
          if (issue.creationDate!.isBefore(groupDate)) {
            status = issue.status;
          }
        }

        if (status != null) {
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
      final groupDate = datedGroups[i].date;

      // TODO: set default status
      if (issue.creationDate!.isBefore(groupDate) ||
          issue.creationDate!.isAtSameMomentAs(groupDate)) {
        IssueStatus? status;

        for (final changelog in filteredChangelog) {
          if (changelog.created!.isBefore(groupDate) ||
              changelog.created!.isAtSameMomentAs(groupDate)) {
            status =
                IssueStatus.fromChangeDetails(changelog.items.where((element) {
              return element.field == 'status';
            }).single);

            break;
          }
        }

        status ??= issue.status!;

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

  Future<EstimationResults> getTotalEstimationFor({
    required String label,
    int weeksAgoCount = 4,
    SamplingFrequency frequency = SamplingFrequency.eachWeek,
  }) async {
    return getTotalEstimationByJql(
      'project = "AS" AND labels in ("$label")',
      weeksAgoCount: weeksAgoCount,
      frequency: frequency,
    );
  }

  static bool doesBelongToGroup(DateTime previousDatedGroup,
      DateTime datedGroup, DateTime changeLogDate) {
    assert(previousDatedGroup.isBefore(datedGroup));

    return (changeLogDate.isAfter(previousDatedGroup) &&
        (changeLogDate.isBefore(datedGroup) ||
            changeLogDate.isAtSameMomentAs(datedGroup)));
  }

  List<Changelog> filterChangelogByStatusAndGroupByDate(
      PageBeanChangelog changelogs) {
    List<Changelog> filteredChangelog = [];

    final List<Changelog> copy = List.from(changelogs.values.reversed);
    for (final changelog in copy) {
      final statusChanges = changelog.items.where((element) {
        final actualField = element.field;
        final expectedField = 'status';
        final isEqual = actualField == expectedField;
        return isEqual;
      }).toList();

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

      assert(statusChanges.length == 1);
      filteredChangelog
          .add(changelog.copyWith(created: date, items: statusChanges));
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

  EstimationResults clone() {
    return EstimationResults(
      ignoredIssues: ignoredIssues.map((e) {
        return IgnoredIssue(
          e.key,
          reason: e.reason,
        );
      }).toList(),
      groupedEstimationAtTheMoment: groupedEstimationAtTheMoment.map((e) {
        return EstimatedGroup(
          groupStatus: IssueStatus(
            id: e.groupStatus.id,
            name: e.groupStatus.name,
          ),
          estimation: e.estimation,
        );
      }).toList(),
      datedGroups: datedGroups.map((e) {
        return GroupedIssuesRecord(
          date: e.date,
          groupedEstimations: e.groupedEstimations.map((e) {
            return EstimatedGroup(
              groupStatus: IssueStatus(
                id: e.groupStatus.id,
                name: e.groupStatus.name,
              ),
              estimation: e.estimation,
            );
          }).toList(),
        );
      }).toList(),
    );
  }
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

class UnauthorizedException implements Exception {}
