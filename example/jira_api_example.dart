import 'package:dotenv/dotenv.dart';
import 'package:jira_api/jira_api.dart';

Future<void> main() async {
  final env = DotEnv();
  env.load();
  final jiraStats = JiraStats(
    user: env['USER_NAME']!,
    apiToken: env['API_TOKEN']!,
  );
  await jiraStats.initialize();
  final searchResults = await jiraStats.getTotalEstimationFor(label: 'MB');

  print('--- Ignored Issues ---');
  for (final ignoredIssue in searchResults.ignoredIssues) {
    print('${ignoredIssue.key} because ${ignoredIssue.reason}');
  }
  print('');
  print('--- Estimation Grouped by Status ---');
  for (final status in searchResults.groupedEstimation.keys) {
    print(
      '${status.name} => ${searchResults.groupedEstimation[status]}',
    );
  }
}
