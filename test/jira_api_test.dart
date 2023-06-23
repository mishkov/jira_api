import 'package:dotenv/dotenv.dart';
import 'package:jira_api/jira_api.dart' show IssueStatus, JiraStats;
import 'package:test/test.dart';

void main() {
  group('getTotalEstimationFor', () {
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

    test('ignoredIssues', () async {
      final result = await jiraStats!.getTotalEstimationFor(label: 'MB');
      expect(result, isNotNull);
      expect(result.ignoredIssues, isNotEmpty);
    });

    test('groupedEstimation', () async {
      final result = await jiraStats!.getTotalEstimationFor(label: 'MB');
      expect(result, isNotNull);
      expect(
          result.groupedEstimationAtTheMoment, isA<Map<IssueStatus, double>>());
      expect(result.groupedEstimationAtTheMoment, isNotEmpty);
    });

    test('doesBelongToGroup', () async {
      final startDate = DateTime(2000, 6, 20);
      final endDate = DateTime(2000, 6, 30);

      expect(
        JiraStats.doesBelongToGroup(startDate, endDate, DateTime(2000, 6, 1)),
        false,
      );
      expect(
        JiraStats.doesBelongToGroup(startDate, endDate, DateTime(2000, 6, 20)),
        false,
      );
      expect(
        JiraStats.doesBelongToGroup(startDate, endDate, DateTime(2000, 6, 21)),
        true,
      );
      expect(
        JiraStats.doesBelongToGroup(startDate, endDate, DateTime(2000, 6, 30)),
        true,
      );
      expect(
        JiraStats.doesBelongToGroup(startDate, endDate, DateTime(2000, 6, 31)),
        false,
      );
    });
  });
}
