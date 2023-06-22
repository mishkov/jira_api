import 'package:dotenv/dotenv.dart';
import 'package:jira_api/jira_api.dart';

Future<void> main() async {
  final env = DotEnv();
  env.load();
  final jiraStats = JiraStats(
    user: env['USER_NAME']!,
    apiToken: env['API_TOKEN']!,
  );
  print(
    'Total estimate for task with MB label is ${await jiraStats.getTotalEstimationFor(label: 'MB')}',
  );
}
