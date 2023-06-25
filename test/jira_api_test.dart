import 'package:atlassian_apis/jira_platform.dart';
import 'package:dotenv/dotenv.dart';
import 'package:jira_api/jira_api.dart';
import 'package:test/test.dart';

void main() {
  group('Jira Stats', () {
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

    test('groupedEstimation for each week', () async {
      final result = await jiraStats!.getTotalEstimationFor(label: 'MB');
      expect(result, isNotNull);
      expect(result.groupedEstimationAtTheMoment, isA<EstimatedGroup>());
      expect(result.groupedEstimationAtTheMoment, isNotEmpty);
    });

    test('groupedEstimation for each day', () async {
      final result = await jiraStats!.getTotalEstimationFor(label: 'MB');
      expect(result, isNotNull);
      expect(result.datedGroups, isNotEmpty);
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

    test('"resolution" String', () async {
      final changelog = Changelog(items: [
        ChangeDetails(field: 'resolution'),
        ChangeDetails(field: 'status'),
      ]);

      final result = changelog.items.where((element) {
        return element.field == 'status';
      });

      expect(result.length, 1);
    });

    test('getLabels', () async {
      final labels = await jiraStats!.getLabels();
      expect(labels, isNotEmpty);
    });
  });
}
