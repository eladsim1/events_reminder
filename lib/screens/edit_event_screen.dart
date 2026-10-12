import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/event.dart';
import '../providers/event_provider.dart';
import '../widgets/event_form.dart';

/// מסך עריכת אירוע קיים. מאפשר שינוי שם, סוג, לוח, תאריך, שעה,
/// הפעלה/כיבוי ההתראה, ומחיקה.
class EditEventScreen extends ConsumerWidget {
  final Event event;

  const EditEventScreen({super.key, required this.event});

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('מחיקת אירוע'),
        content: Text('למחוק את האירוע של ${event.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('ביטול'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('מחיקה'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(eventListProvider.notifier).deleteEvent(event);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('עריכת אירוע'),
        actions: [
          IconButton(
            tooltip: 'מחיקה',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, ref),
          ),
        ],
      ),
      body: EventForm(
        initial: event,
        defaultHour: event.notificationHour,
        defaultMinute: event.notificationMinute,
        showEnabledToggle: true,
        onSubmit: (result) async {
          final updated = event.copyWith(
            name: result.name,
            kind: result.kind,
            calendar: result.calendar,
            day: result.day,
            month: result.month,
            adarType: result.adarType,
            startYear: result.startYear,
            clearStartYear: result.startYear == null,
            notificationHour: result.hour,
            notificationMinute: result.minute,
            enabled: result.enabled,
            notes: result.notes,
            clearNotes: result.notes == null,
            reminderMode: result.reminderMode,
            reminderValue: result.reminderValue,
          );

          try {
            await ref.read(eventListProvider.notifier).updateEvent(updated);
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
