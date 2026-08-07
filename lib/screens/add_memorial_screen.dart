import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/memorial.dart';
import '../providers/memorial_provider.dart';
import '../widgets/memorial_form.dart';

/// מסך הוספת אזכרה חדשה.
class AddMemorialScreen extends ConsumerWidget {
  const AddMemorialScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defaultTime = ref.watch(defaultReminderTimeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('הוספת אזכרה')),
      body: MemorialForm(
        defaultHour: defaultTime.hour,
        defaultMinute: defaultTime.minute,
        photoPicker: () => ref.read(photoStoreProvider).pickAndStore(),
        onSubmit: (result) async {
          final storage = result.month.toStorage();
          final memorial = Memorial(
            name: result.name,
            hebrewDay: result.day,
            hebrewMonth: storage.baseMonth,
            adarType: storage.adarType,
            notificationHour: result.hour,
            notificationMinute: result.minute,
            enabled: result.enabled,
            notes: result.notes,
            cemetery: result.cemetery,
            plot: result.plot,
            photoPath: result.photoPath,
            reminderMode: result.reminderMode,
            reminderValue: result.reminderValue,
            deathHebrewYear: result.deathHebrewYear,
            createdAt: DateTime.now(),
          );

          try {
            await ref
                .read(memorialListProvider.notifier)
                .addMemorial(memorial);
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
