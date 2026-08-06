import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/memorial.dart';
import '../providers/memorial_provider.dart';
import '../widgets/memorial_form.dart';

/// מסך עריכת אזכרה קיימת. מאפשר שינוי שם, תאריך, שעה,
/// הפעלה/כיבוי ההתראה, ומחיקה.
class EditMemorialScreen extends ConsumerWidget {
  final Memorial memorial;

  const EditMemorialScreen({super.key, required this.memorial});

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('מחיקת אזכרה'),
        content: Text('למחוק את האזכרה של ${memorial.name}?'),
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
      await ref
          .read(memorialListProvider.notifier)
          .deleteMemorial(memorial);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('עריכת אזכרה'),
        actions: [
          IconButton(
            tooltip: 'מחיקה',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(context, ref),
          ),
        ],
      ),
      body: MemorialForm(
        initial: memorial,
        defaultHour: memorial.notificationHour,
        defaultMinute: memorial.notificationMinute,
        showEnabledToggle: true,
        photoPicker: () => ref.read(photoStoreProvider).pickAndStore(),
        onSubmit: (result) async {
          final storage = result.month.toStorage();
          final updated = memorial.copyWith(
            name: result.name,
            hebrewDay: result.day,
            hebrewMonth: storage.baseMonth,
            adarType: storage.adarType,
            notificationHour: result.hour,
            notificationMinute: result.minute,
            enabled: result.enabled,
            notes: result.notes,
            clearNotes: result.notes == null,
            cemetery: result.cemetery,
            plot: result.plot,
            photoPath: result.photoPath,
            clearPhoto: result.photoPath == null,
            reminderMode: result.reminderMode,
            reminderValue: result.reminderValue,
          );

          try {
            await ref
                .read(memorialListProvider.notifier)
                .updateMemorial(updated);
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
