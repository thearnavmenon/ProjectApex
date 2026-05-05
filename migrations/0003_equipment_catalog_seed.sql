-- Migration: 0003_equipment_catalog_seed.sql
-- Phase 1 / Slice 4 (#7) — seed equipment_catalog with 42 design-reviewed entries
--
-- Idempotent: INSERT … ON CONFLICT (id) DO NOTHING means re-running never
-- overwrites existing rows and never fails on a database that already has the
-- seed applied.
--
-- Authoritative row data mirrors Resources/equipment_catalog_seed.json.
-- Categories: plate-loaded | weight-stack | fixed-weight | bodyweight
-- Locked muscle groups: back | chest | biceps | shoulders | triceps | legs

-- ---------------------------------------------------------------------------
-- 26 base entries — sourced from EquipmentType enum (excluding unknown(String))
-- ---------------------------------------------------------------------------

INSERT INTO public.equipment_catalog
    (id, display_name, category, default_max_kg, default_increment_kg, primary_muscle_groups, exercise_tags)
VALUES
    ('dumbbell-set',          'Dumbbell Set',          'fixed-weight',  60,   2.5,
     ARRAY['chest','back','shoulders','biceps','triceps','legs'],
     ARRAY['dumbbell press','dumbbell row','dumbbell curl','dumbbell fly','lateral raise','dumbbell lunge','dumbbell shoulder press','dumbbell tricep extension']),

    ('barbell',               'Barbell',               'plate-loaded',  200,  2.5,
     ARRAY['chest','back','shoulders','legs','biceps','triceps'],
     ARRAY['bench press','squat','deadlift','barbell row','overhead press','Romanian deadlift','barbell curl']),

    ('ez-curl-bar',           'EZ Curl Bar',           'plate-loaded',  80,   2.5,
     ARRAY['biceps','triceps'],
     ARRAY['EZ-bar curl','EZ-bar skull crushers','EZ-bar overhead extension']),

    ('cable-machine',         'Cable Machine',         'weight-stack',  100,  5,
     ARRAY['chest','back','shoulders','biceps','triceps','legs'],
     ARRAY['cable fly','cable row','cable curl','tricep pushdown','cable lateral raise','cable face pull','cable kickback']),

    ('cable-machine-dual',    'Cable Machine (Dual)',  'weight-stack',  100,  5,
     ARRAY['chest','back','shoulders','biceps','triceps'],
     ARRAY['cable crossover','cable fly','cable row','cable curl','cable lateral raise','cable face pull','tricep pushdown']),

    ('smith-machine',         'Smith Machine',         'plate-loaded',  200,  2.5,
     ARRAY['chest','back','shoulders','legs','triceps'],
     ARRAY['Smith machine squat','Smith machine bench press','Smith machine row','Smith machine overhead press','Smith machine Romanian deadlift']),

    ('leg-press',             'Leg Press',             'plate-loaded',  400,  10,
     ARRAY['legs'],
     ARRAY['leg press','high-foot leg press','single-leg press','narrow-stance leg press']),

    ('hack-squat',            'Hack Squat',            'plate-loaded',  300,  10,
     ARRAY['legs'],
     ARRAY['hack squat','reverse hack squat','narrow-stance hack squat']),

    ('adjustable-bench',      'Adjustable Bench',      'bodyweight',    NULL, NULL,
     ARRAY['chest','shoulders','back','triceps','biceps'],
     ARRAY['dumbbell press','dumbbell fly','dumbbell row','incline press','seated curl','step-up']),

    ('flat-bench',            'Flat Bench',            'bodyweight',    NULL, NULL,
     ARRAY['chest','triceps','shoulders'],
     ARRAY['barbell bench press','dumbbell bench press','dumbbell fly','close-grip bench press']),

    ('incline-bench',         'Incline Bench',         'bodyweight',    NULL, NULL,
     ARRAY['chest','shoulders','biceps'],
     ARRAY['incline barbell press','incline dumbbell press','incline dumbbell fly','incline curl']),

    ('pull-up-bar',           'Pull-Up Bar',           'bodyweight',    NULL, NULL,
     ARRAY['back','biceps'],
     ARRAY['pull-up','chin-up','wide-grip pull-up','hanging leg raise']),

    ('dip-station',           'Dip Station',           'bodyweight',    NULL, NULL,
     ARRAY['chest','triceps','shoulders'],
     ARRAY['tricep dip','chest dip','L-sit']),

    ('resistance-bands',      'Resistance Bands',      'fixed-weight',  50,   5,
     ARRAY['back','shoulders','biceps','chest','legs','triceps'],
     ARRAY['band pull-apart','band curl','band face pull','band lateral raise','banded squat','band tricep pushdown']),

    ('kettlebell-set',        'Kettlebell Set',        'fixed-weight',  40,   4,
     ARRAY['back','shoulders','legs','biceps'],
     ARRAY['kettlebell swing','kettlebell goblet squat','kettlebell press','kettlebell row','Turkish get-up']),

    ('power-rack',            'Power Rack',            'plate-loaded',  200,  2.5,
     ARRAY['chest','back','legs','shoulders','triceps'],
     ARRAY['barbell squat','barbell bench press','overhead press','rack pull','barbell row','pin press']),

    ('squat-rack',            'Squat Rack',            'plate-loaded',  200,  2.5,
     ARRAY['legs','shoulders','back'],
     ARRAY['barbell squat','overhead press','front squat','rack pull']),

    ('lat-pulldown',          'Lat Pulldown',          'weight-stack',  100,  5,
     ARRAY['back','biceps'],
     ARRAY['lat pulldown','close-grip pulldown','wide-grip pulldown','single-arm pulldown']),

    ('seated-row',            'Seated Row',            'weight-stack',  100,  5,
     ARRAY['back','biceps'],
     ARRAY['seated cable row','close-grip row','wide-grip row','single-arm seated row']),

    ('chest-press-machine',   'Chest Press Machine',   'weight-stack',  150,  5,
     ARRAY['chest','triceps','shoulders'],
     ARRAY['machine chest press','machine incline press','single-arm chest press']),

    ('shoulder-press-machine','Shoulder Press Machine','weight-stack',  120,  5,
     ARRAY['shoulders','triceps'],
     ARRAY['machine shoulder press','machine overhead press','single-arm shoulder press']),

    ('leg-extension',         'Leg Extension',         'weight-stack',  120,  5,
     ARRAY['legs'],
     ARRAY['leg extension','single-leg extension']),

    ('leg-curl',              'Leg Curl',              'weight-stack',  100,  5,
     ARRAY['legs'],
     ARRAY['lying leg curl','seated leg curl','single-leg curl']),

    ('pec-deck',              'Pec Deck',              'weight-stack',  100,  5,
     ARRAY['chest'],
     ARRAY['pec deck fly','machine fly','reverse pec deck']),

    ('preacher-curl',         'Preacher Curl',         'weight-stack',  80,   5,
     ARRAY['biceps'],
     ARRAY['preacher curl','EZ-bar preacher curl','dumbbell preacher curl','machine preacher curl']),

    ('cable-crossover',       'Cable Crossover',       'weight-stack',  100,  5,
     ARRAY['chest','shoulders','triceps'],
     ARRAY['cable crossover','cable fly','low-to-high cable fly','high-to-low cable fly'])

ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 16 specialty entries — per ADR-0004
-- ---------------------------------------------------------------------------

INSERT INTO public.equipment_catalog
    (id, display_name, category, default_max_kg, default_increment_kg, primary_muscle_groups, exercise_tags)
VALUES
    ('hip-thrust-machine',        'Hip Thrust Machine',              'weight-stack',  200,  5,
     ARRAY['legs'],
     ARRAY['machine hip thrust','glute bridge','hip thrust']),

    ('ghd-glute-ham-raise',       'GHD / Glute-Ham Raise',           'bodyweight',    NULL, NULL,
     ARRAY['legs','back'],
     ARRAY['glute-ham raise','GHD sit-up','Nordic curl','GHD hyperextension']),

    ('reverse-hyper',             'Reverse Hyper',                   'plate-loaded',  100,  5,
     ARRAY['legs','back'],
     ARRAY['reverse hyperextension','reverse hyper']),

    ('t-bar-row',                 'T-Bar Row',                       'plate-loaded',  150,  5,
     ARRAY['back','biceps'],
     ARRAY['T-bar row','landmine row','chest-supported T-bar row']),

    ('trap-bar',                  'Trap Bar',                        'plate-loaded',  250,  2.5,
     ARRAY['legs','back','shoulders'],
     ARRAY['trap bar deadlift','trap bar squat','trap bar shrug','trap bar farmer carry']),

    ('belt-squat-pendulum-squat', 'Belt Squat / Pendulum Squat',     'plate-loaded',  300,  10,
     ARRAY['legs'],
     ARRAY['belt squat','pendulum squat','belt squat split squat','goblet belt squat']),

    ('hs-chest-press',            'Hammer Strength Chest Press',     'plate-loaded',  200,  5,
     ARRAY['chest','triceps','shoulders'],
     ARRAY['Hammer Strength chest press','plate-loaded chest press','unilateral chest press']),

    ('hs-incline-press',          'Hammer Strength Incline Press',   'plate-loaded',  180,  5,
     ARRAY['chest','shoulders','triceps'],
     ARRAY['Hammer Strength incline press','plate-loaded incline press','unilateral incline press']),

    ('hs-lat-pulldown',           'Hammer Strength Lat Pulldown',    'plate-loaded',  180,  5,
     ARRAY['back','biceps'],
     ARRAY['Hammer Strength lat pulldown','plate-loaded lat pulldown','unilateral lat pulldown']),

    ('hs-iso-row',                'Hammer Strength ISO-Row',         'plate-loaded',  180,  5,
     ARRAY['back','biceps'],
     ARRAY['Hammer Strength ISO row','plate-loaded row','unilateral row','chest-supported row']),

    ('hs-shoulder-press',         'Hammer Strength Shoulder Press',  'plate-loaded',  150,  5,
     ARRAY['shoulders','triceps'],
     ARRAY['Hammer Strength shoulder press','plate-loaded shoulder press','unilateral shoulder press']),

    ('standing-calf-raise',       'Standing Calf Raise',             'plate-loaded',  300,  5,
     ARRAY['legs'],
     ARRAY['standing calf raise','single-leg calf raise','donkey calf raise']),

    ('seated-calf-raise',         'Seated Calf Raise',               'plate-loaded',  150,  5,
     ARRAY['legs'],
     ARRAY['seated calf raise','single-leg seated calf raise']),

    ('abductor-machine',          'Abductor Machine',                'weight-stack',  100,  5,
     ARRAY['legs'],
     ARRAY['hip abductor','outer thigh machine']),

    ('adductor-machine',          'Adductor Machine',                'weight-stack',  100,  5,
     ARRAY['legs'],
     ARRAY['hip adductor','inner thigh machine','adductor press']),

    ('sissy-squat-machine',       'Sissy Squat Machine',             'bodyweight',    NULL, NULL,
     ARRAY['legs'],
     ARRAY['sissy squat','machine sissy squat'])

ON CONFLICT (id) DO NOTHING;
