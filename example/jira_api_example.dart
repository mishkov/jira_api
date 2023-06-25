import 'dart:math' as math;

import 'package:dotenv/dotenv.dart';
import 'package:intl/intl.dart';
import 'package:jira_api/jira_api.dart';

Future<void> main() async {
  final env = DotEnv();
  env.load();
  final jiraStats = JiraStats(
    user: env['USER_NAME']!,
    apiToken: env['API_TOKEN']!,
  );
  await jiraStats.initialize();
  final searchResults = await jiraStats.getTotalEstimationFor(
    label: 'MB',
    weeksAgoCount: 40,
  );

  print('--- Ignored Issues ---');
  for (final ignoredIssue in searchResults.ignoredIssues) {
    print('${ignoredIssue.key} because ${ignoredIssue.reason}');
  }
  print('');
  print('--- Estimation for MB Label Grouped by Status at the Moment ---');
  for (final estimationGroup in searchResults.groupedEstimationAtTheMoment) {
    print(
      '${estimationGroup.groupStatus.name} => ${estimationGroup.estimation}',
    );
  }

  final allStatus = searchResults.datedGroups.fold<Set<IssueStatus>>({},
      (allStatuses, record) {
    return allStatuses
      ..addAll(record.groupedEstimations.fold<Set<IssueStatus>>({},
          (innerStatuses, group) {
        return innerStatuses..add(group.groupStatus);
      }));
  });

  int maxLengthStatus = 0;
  for (final status in allStatus) {
    maxLengthStatus = math.max(maxLengthStatus, status.name.length);
  }

  const dateFormat = 'yyyy-MM-dd';
  final DateFormat formatter = DateFormat(dateFormat);

  final tableWidth = (allStatus.length + 4) +
      dateFormat.length +
      (maxLengthStatus + 2) * allStatus.length;
  final title = ' History of Estimation for MB Label Grouped by Status ';
  final padding = '=' * ((tableWidth - title.length) ~/ 2);
  print('=' * tableWidth);
  print('$padding$title$padding'.padRight(tableWidth, '='));
  print('=' * tableWidth);
  String statusesString = '';
  for (final status in allStatus) {
    statusesString += ' ${status.name.padRight(maxLengthStatus, " ")} |';
  }
  print('| $dateFormat |$statusesString');
  print('=' * tableWidth);
  for (final group in searchResults.datedGroups) {
    String esmitationsString = '';
    for (final status in allStatus) {
      final estimatedGroup = group.groupedEstimations
          .where((element) => element.groupStatus == status);

      final String estimation;
      if (estimatedGroup.isNotEmpty) {
        estimation = estimatedGroup.single.estimation.toString();
      } else {
        estimation = '---';
      }

      esmitationsString += ' ${estimation.padRight(maxLengthStatus, " ")} |';
    }
    print('| ${formatter.format(group.date)} |$esmitationsString');
  }
  print('=' * tableWidth);
}
