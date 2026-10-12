import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/event.dart';
import '../providers/event_provider.dart';
import '../widgets/event_form.dart';

/// מסך הוספת אירוע חדש.
class AddEventScreen extends ConsumerWidget {
  const AddEventScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defaultTime = ref.watch(defaultReminderTimeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('הוספת אירוע')),
      body: EventForm(
        defaultHour: defaultTime.hour,
        defaultMinute: defaultTime.minute,
        onSubmit: (result) async {
          final event = Event(
            name: result.name,
            kind: result.kind,
            calendar: result.calendar,
            day: result.day,
            month: result.month,
            adarType: result.adarType,
            startYear: result.startYear,
            notificationHour: result.hour,
            notificationMinute: result.minute,
            enabled: result.enabled,
            notes: result.notes,
            reminderMode: result.reminderMode,
            reminderValue: result.reminderValue,
            createdAt: DateTime.now(),
          );

          try {
            await ref.read(eventListProvider.notifier).addEvent(event);
            if (context.mounted) Navigator.of(context).pop();
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('שגיאה בשמירה: $e')),
              );
            }
          }
        },
      ),
    );
  }
}
