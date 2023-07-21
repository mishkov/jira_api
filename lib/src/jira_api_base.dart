import 'dart:convert';
import 'dart:developer';

import 'package:atlassian_apis/jira_platform.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart';

enum SamplingFrequency { eachWeek, eachDay }

extension SerializableSamplingFrequency on SamplingFrequency {
  String toMap() {
    return toString();
  }

  static SamplingFrequency fromMap(String map) {
    return SamplingFrequency.values.singleWhere(
      (element) {
        return element.toMap() == map;
      },
    );
  }

  String toJson() => json.encode(toMap());

  static SamplingFrequency fromJson(String source) =>
      SerializableSamplingFrequency.fromMap(source);
}

class JiraStats {
  /// Email address of your account. Like test@gmail.com
  final String user;

  /// Api Token that you generate in your account settings
  final String apiToken;

  /// Will be used in <your-account>.atlassian.net domain to access atlassian
  /// api.
  final String accountName;

  final _statusField = 'status';

  ApiClient? _apiClient;
  JiraPlatformApi? _jira;

  JiraStats({
    required this.user,
    required this.apiToken,
    required this.accountName,
  });

  Future<void> initialize({BaseClient? client}) async {
    // final client = MyClient();

    // get(Uri.parse('https://www.google.com'));

    // Create an authenticated http client.
    _apiClient = ApiClient.basicAuthentication(
      Uri.https('$accountName.atlassian.net', ''),
      user: user,
      apiToken: apiToken,
      client: client,
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

  Future<List<String>> getLabels({int maxResults = 100}) async {
    if (_jira == null) {
      throw JiraNotInitializedException();
    }

    final page = await _jira!.labels.getAllLabels(maxResults: maxResults);
    return page.values;
  }

  /// Returns a list of error messages for passed [jql]
  Future<List<String>> validateJql(String jql) async {
    if (_jira == null) {
      throw JiraNotInitializedException();
    }

    final parsedJql = await _jira!.jql
        .parseJqlQueries(body: JqlQueriesToParse(queries: [jql]));

    return parsedJql.queries.single.errors;
  }

  /// Checks if Jira contains issue's field with passed [fieldId] and
  /// check if it has correct type. If field does not exit then throws
  /// [FieldNotFoundException].
  Future<void> validateStoryPoitnsField(String fieldId) async {
    if (_jira == null) {
      throw JiraNotInitializedException();
    }

    final fields = await _jira!.issueFields.getFields();

    final possibleStoryPointsFields = fields.where((jiraField) {
      return jiraField.id == fieldId;
    });

    if (possibleStoryPointsFields.isEmpty) {
      throw FieldNotFoundException();
    }

    final storyPointsField = possibleStoryPointsFields.single;

    if (storyPointsField.schema?.type != 'number') {
      throw InvalidFieldTypeException();
    }
  }

  /// [storyPointEstimateField] is a name of field that represents task
  /// esmitaion's points in your Jira projects. It must be [num] or [String]
  /// that can be converted into [num].
  Future<EstimationResults> getTotalEstimationByJql(
    String jql, {
    int weeksAgoCount = 4,
    SamplingFrequency frequency = SamplingFrequency.eachWeek,
    required String storyPointEstimateField,
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
      const createDateField = 'created';
      final searchResults = await _jira!.issueSearch.searchForIssuesUsingJql(
        jql: jql,
        fields: [
          storyPointEstimateField,
          _statusField,
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

        final rawStatus = issue.fields![_statusField];

        if (rawStatus is! Map<String, dynamic>) {
          ignoredIssues.add(IgnoredIssue(
            issue.key ?? issue.id,
            reason: '$_statusField field is not Map or is null',
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

      if (issue.creationDate!.isBefore(groupDate) ||
          issue.creationDate!.isAtSameMomentAs(groupDate)) {
        IssueStatus? status;

        for (final changelog in filteredChangelog) {
          if (changelog.created!.isBefore(groupDate) ||
              changelog.created!.isAtSameMomentAs(groupDate)) {
            status =
                IssueStatus.fromChangeDetails(changelog.items.where((element) {
              return element.field == _statusField;
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
        final isEqual = actualField == _statusField;
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

  Map<String, dynamic> toMap() {
    return {
      'ignoredIssues': ignoredIssues.map((x) => x.toMap()).toList(),
      'groupedEstimationAtTheMoment':
          groupedEstimationAtTheMoment.map((x) => x.toMap()).toList(),
      'datedGroups': datedGroups.map((x) => x.toMap()).toList(),
    };
  }

  factory EstimationResults.fromMap(Map<String, dynamic> map) {
    return EstimationResults(
      ignoredIssues: List<IgnoredIssue>.from(
          map['ignoredIssues']?.map((x) => IgnoredIssue.fromMap(x))),
      groupedEstimationAtTheMoment: List<EstimatedGroup>.from(
          map['groupedEstimationAtTheMoment']
              ?.map((x) => EstimatedGroup.fromMap(x))),
      datedGroups: List<GroupedIssuesRecord>.from(
          map['datedGroups']?.map((x) => GroupedIssuesRecord.fromMap(x))),
    );
  }

  String toJson() => json.encode(toMap());

  factory EstimationResults.fromJson(String source) =>
      EstimationResults.fromMap(json.decode(source));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    final listEquals = const DeepCollectionEquality().equals;

    return other is EstimationResults &&
        listEquals(other.ignoredIssues, ignoredIssues) &&
        listEquals(
            other.groupedEstimationAtTheMoment, groupedEstimationAtTheMoment) &&
        listEquals(other.datedGroups, datedGroups);
  }

  @override
  int get hashCode =>
      ignoredIssues.hashCode ^
      groupedEstimationAtTheMoment.hashCode ^
      datedGroups.hashCode;
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

  Map<String, dynamic> toMap() {
    return {
      'key': key,
      'estimation': estimation,
      'creationDate': creationDate?.millisecondsSinceEpoch,
      'status': status?.toMap(),
    };
  }

  factory Issue.fromMap(Map<String, dynamic> map) {
    return Issue(
      map['key'],
      estimation: map['estimation']?.toDouble(),
      creationDate: map['creationDate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['creationDate'])
          : null,
      status: map['status'] != null ? IssueStatus.fromMap(map['status']) : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory Issue.fromJson(String source) => Issue.fromMap(json.decode(source));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is Issue &&
        other.key == key &&
        other.estimation == estimation &&
        other.creationDate == creationDate &&
        other.status == status;
  }

  @override
  int get hashCode {
    return key.hashCode ^
        estimation.hashCode ^
        creationDate.hashCode ^
        status.hashCode;
  }
}

class IgnoredIssue extends Issue {
  final String reason;

  IgnoredIssue(
    super.key, {
    required this.reason,
  });

  @override
  Map<String, dynamic> toMap() {
    return {
      'key': key,
      'reason': reason,
    };
  }

  factory IgnoredIssue.fromMap(Map<String, dynamic> map) {
    return IgnoredIssue(
      map['key'] ?? '',
      reason: map['reason'] ?? '',
    );
  }

  @override
  String toJson() => json.encode(toMap());

  factory IgnoredIssue.fromJson(String source) =>
      IgnoredIssue.fromMap(json.decode(source));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is IgnoredIssue && other.reason == reason;
  }

  @override
  int get hashCode => reason.hashCode;
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

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
    };
  }

  String toJson() => json.encode(toMap());
}

class EstimatedGroup {
  final IssueStatus groupStatus;
  double estimation;

  EstimatedGroup({
    required this.groupStatus,
    this.estimation = 0.0,
  });

  Map<String, dynamic> toMap() {
    return {
      'groupStatus': groupStatus.toMap(),
      'estimation': estimation,
    };
  }

  factory EstimatedGroup.fromMap(Map<String, dynamic> map) {
    return EstimatedGroup(
      groupStatus: IssueStatus.fromMap(map['groupStatus']),
      estimation: map['estimation']?.toDouble() ?? 0.0,
    );
  }

  String toJson() => json.encode(toMap());

  factory EstimatedGroup.fromJson(String source) =>
      EstimatedGroup.fromMap(json.decode(source));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is EstimatedGroup &&
        other.groupStatus == groupStatus &&
        other.estimation == estimation;
  }

  @override
  int get hashCode => groupStatus.hashCode ^ estimation.hashCode;
}

class GroupedIssuesRecord {
  final DateTime date;
  final List<EstimatedGroup> groupedEstimations;

  GroupedIssuesRecord({
    required this.date,
    required this.groupedEstimations,
  });

  Map<String, dynamic> toMap() {
    return {
      'date': date.millisecondsSinceEpoch,
      'groupedEstimations': groupedEstimations.map((x) => x.toMap()).toList(),
    };
  }

  factory GroupedIssuesRecord.fromMap(Map<String, dynamic> map) {
    return GroupedIssuesRecord(
      date: DateTime.fromMillisecondsSinceEpoch(map['date']),
      groupedEstimations: List<EstimatedGroup>.from(
          map['groupedEstimations']?.map((x) => EstimatedGroup.fromMap(x))),
    );
  }

  String toJson() => json.encode(toMap());

  factory GroupedIssuesRecord.fromJson(String source) =>
      GroupedIssuesRecord.fromMap(json.decode(source));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    final listEquals = const DeepCollectionEquality().equals;

    return other is GroupedIssuesRecord &&
        other.date == date &&
        listEquals(other.groupedEstimations, groupedEstimations);
  }

  @override
  int get hashCode => date.hashCode ^ groupedEstimations.hashCode;
}

class UnauthorizedException implements Exception {}

class FieldNotFoundException implements Exception {}

class InvalidFieldTypeException implements Exception {}
