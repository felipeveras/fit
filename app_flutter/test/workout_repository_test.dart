import 'dart:io';

import 'package:app_fit/core/persistence/app_database.dart';
import 'package:app_fit/features/workout/workout_models.dart';
import 'package:app_fit/features/workout/workout_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory directory;
  late AppDatabase database;
  late WorkoutRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('app-fit-workout-test');
    database = AppDatabase(factory: databaseFactoryFfi);
    await database.open(databasePath: '${directory.path}/app_fit.db');
    repository = WorkoutRepository(database);
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('seeds a searchable library and persists custom exercises', () async {
    final seeded = await repository.listExercises(muscleGroup: 'chest');
    expect(seeded, isNotEmpty);
    expect(seeded.every((exercise) => !exercise.isCustom), isTrue);

    final customId = await repository.saveCustomExercise(
      const ExerciseDefinition(
        name: 'Supino com pegada fechada',
        muscleGroup: 'triceps',
        instructions: 'Mantenha os cotovelos próximos ao tronco.',
      ),
    );
    final found = await repository.listExercises(
      query: 'pegada fechada',
      muscleGroup: 'triceps',
    );
    expect(found.single.id, customId);
    expect(found.single.isCustom, isTrue);

    await repository.saveCustomExercise(
      ExerciseDefinition(
        id: customId,
        name: 'Supino fechado',
        muscleGroup: 'chest',
      ),
    );
    expect(
      (await repository.listExercises(query: 'Supino fechado')).single.id,
      customId,
    );
    await repository.deleteCustomExercise(customId);
    expect(await repository.listExercises(query: 'Supino fechado'), isEmpty);
  });

  test(
    'creates, edits, duplicates and deletes an ordered scheduled routine',
    () async {
      final exercises = await repository.listExercises(muscleGroup: 'chest');
      final routineId = await repository.createRoutine(
        WorkoutRoutine(
          name: 'Peito A',
          notes: 'Aumentar carga quando completar as reps.',
          scheduledWeekdays: const [1, 4],
          exercises: [
            RoutineExercise(
              exerciseId: exercises[1].id!,
              position: 1,
              plannedSets: 4,
              minReps: 6,
              maxReps: 10,
              restSeconds: 120,
              supersetGroup: 'A',
            ),
            RoutineExercise(
              exerciseId: exercises[0].id!,
              position: 0,
              plannedSets: 3,
              minReps: 8,
              maxReps: 12,
            ),
          ],
        ),
      );

      final saved = (await repository.getRoutine(routineId))!;
      expect(saved.scheduledWeekdays, [1, 4]);
      expect(saved.exercises.map((exercise) => exercise.position), [0, 1]);
      expect(saved.exercises.last.supersetGroup, 'A');

      await repository.updateRoutine(
        WorkoutRoutine(
          id: routineId,
          name: 'Peito A revisado',
          scheduledWeekdays: const [2],
          exercises: [saved.exercises.last],
        ),
      );
      final updated = (await repository.getRoutine(routineId))!;
      expect(updated.name, 'Peito A revisado');
      expect(updated.scheduledWeekdays, [2]);
      expect(updated.exercises, hasLength(1));

      final copyId = await repository.duplicateRoutine(routineId);
      final copy = (await repository.getRoutine(copyId))!;
      expect(copy.name, 'Peito A revisado (cópia)');
      expect(
        copy.exercises.single.exerciseId,
        updated.exercises.single.exerciseId,
      );

      await repository.deleteRoutine(routineId);
      expect(await repository.getRoutine(routineId), isNull);
      expect((await repository.listRoutines()).single.id, copyId);
    },
  );

  test('rejects invalid routine data before writing', () async {
    expect(
      () => repository.createRoutine(
        const WorkoutRoutine(name: 'Rotina inválida', scheduledWeekdays: [8]),
      ),
      throwsArgumentError,
    );
    expect(await repository.listRoutines(), isEmpty);
  });
}
