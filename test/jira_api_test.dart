
import 'package:dotenv/dotenv.dart';
import 'package:jira_api/jira_api.dart' show JiraStats;
import 'package:test/test.dart';

void main() {
  group('Smoke test', () {
    JiraStats? jiraStats;

    setUp(() async {
      final env = DotEnv();
      env.load();
      jiraStats = JiraStats(
        user: env['USER_NAME']!,
        apiToken: env['API_TOKEN']!,
      );
      await jiraStats!.initialize();
    });

    test('getTotalEstimationFor MB labels', () async {
      expect(await jiraStats!.getTotalEstimationFor(label: 'MB'), isNotNull);
      expect(await jiraStats!.getTotalEstimationFor(label: 'MB'), isPositive);
    });
  });
}
