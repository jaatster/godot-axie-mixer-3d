using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using SkyMavis.AxieMixer3D;
using SkyMavis.AxieMixer3D.WeaponAnims;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

namespace SkyMavis.AxieMixer3D.Dev.Editor
{
    /// <summary>
    /// Playable oracle: drives the *real* <see cref="AxiePlayable"/> (PlayableGraph + Animator) in
    /// Play mode with a fixed frame delta and records the posed transforms plus the animator state
    /// at chosen frames, for a scripted set of scenarios (one-shot → default, crossfades, queues,
    /// 1D blends with phase-lock, default blends, pause/resume/time-scale, interrupt, start offsets,
    /// seek, Complete(), user-registered clips). The Godot gate `tests/playable_oracle_compare.gd`
    /// replays the very same step list through the GDScript <c>AxiePlayable</c> and compares.
    ///
    /// Why Play mode: the graph runs in <c>DirectorUpdateMode.GameTime</c> and the fade envelope reads
    /// <c>Time.deltaTime</c>; <see cref="Time.captureDeltaTime"/> makes both deterministic
    /// (exactly <see cref="Dt"/> per frame, independent of wall-clock). Domain/scene reload are
    /// disabled for the run so the static state survives entering Play mode.
    ///
    /// Frame model (both engines): at frame k the scenario's steps for k are applied, then the
    /// animator ticks once with <see cref="Dt"/>, then the pose is sampled.
    ///
    ///   AXIE_GODOT_PLAYABLE_DIR=… Unity -batchmode -projectPath … \
    ///     -executeMethod SkyMavis.AxieMixer3D.Dev.Editor.AxiePlayableOracle.Export -logFile …
    ///
    /// Do NOT pass -quit: the method returns before Play mode starts; the runner exits the editor
    /// itself when done (exit code 0, or 1 on failure).
    /// </summary>
    public static class AxiePlayableOracle
    {
        public static readonly string DefaultDir = AxieGltfExporter.GodotRepo + "/tests/playable_oracle";
        public const float Dt = 1f / 60f;
        public const int FormatVersion = 1;

        internal static string OutDir;
        internal static bool Failed;
        static bool _prevOptionsEnabled;
        static EnterPlayModeOptions _prevOptions;

        [MenuItem("Tools/Axie Mixer 3D/Export playable oracle for Godot", priority = 91)]
        public static void Export()
        {
            try
            {
                OutDir = Path.GetFullPath(AxieGltfExporter.Env("AXIE_GODOT_PLAYABLE_DIR", DefaultDir));
                if (Directory.Exists(OutDir)) Directory.Delete(OutDir, true);
                Directory.CreateDirectory(OutDir);
                Failed = false;

                _prevOptionsEnabled = EditorSettings.enterPlayModeOptionsEnabled;
                _prevOptions = EditorSettings.enterPlayModeOptions;
                EditorSettings.enterPlayModeOptionsEnabled = true;
                EditorSettings.enterPlayModeOptions = EnterPlayModeOptions.DisableDomainReload | EnterPlayModeOptions.DisableSceneReload;

                EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
                EditorApplication.playModeStateChanged -= OnPlayModeChanged;
                EditorApplication.playModeStateChanged += OnPlayModeChanged;
                Debug.Log($"[AxiePlayableOracle] → {OutDir} (entering Play mode)");
                EditorApplication.EnterPlaymode();
            }
            catch (Exception ex)
            {
                Debug.LogError($"[AxiePlayableOracle] FAILED: {ex}");
                if (Application.isBatchMode) EditorApplication.Exit(1);
                else throw;
            }
        }

        static void OnPlayModeChanged(PlayModeStateChange state)
        {
            switch (state)
            {
                case PlayModeStateChange.EnteredPlayMode:
                    Time.captureDeltaTime = Dt;
                    Time.timeScale = 1f;
                    Application.targetFrameRate = -1;
                    QualitySettings.vSyncCount = 0;
                    new GameObject("AxiePlayableOracleRunner").AddComponent<AxiePlayableOracleRunner>();
                    break;
                case PlayModeStateChange.EnteredEditMode:
                    EditorApplication.playModeStateChanged -= OnPlayModeChanged;
                    Time.captureDeltaTime = 0f;
                    EditorSettings.enterPlayModeOptionsEnabled = _prevOptionsEnabled;
                    EditorSettings.enterPlayModeOptions = _prevOptions;
                    Debug.Log(Failed ? "[AxiePlayableOracle] FAILED" : "[AxiePlayableOracle] DONE");
                    if (Application.isBatchMode) EditorApplication.Exit(Failed ? 1 : 0);
                    break;
            }
        }

        // -------------------------------------------------------------------------
        // Scenario script
        // -------------------------------------------------------------------------

        internal sealed class Step
        {
            public int Frame;
            public string Op;
            public string Clip;
            public string Name;
            public bool Loop;
            public float Fade = -1f;
            public float TimeScale = 1f;
            public float NormalizedStart;
            public float StartTime;
            public float Value;
            public bool Play = true;
            public List<(string clip, float threshold)> Points;
        }

        internal sealed class Scenario
        {
            public string Name;
            public List<Step> Steps = new();
            public SortedSet<int> SampleFrames = new();
            public int LastFrame => SampleFrames.Count > 0 ? SampleFrames.Max : 0;

            public Scenario At(int frame, Step s) { s.Frame = frame; Steps.Add(s); return this; }
            public Scenario Sample(params int[] frames) { foreach (var f in frames) if (f >= 0) SampleFrames.Add(f); return this; }
        }

        static readonly (string clip, float threshold)[] LocoPoints = { ("Idle", 0f), ("Walk", 1f), ("Run", 2f) };

        static Step SetDefault(string clip) => new() { Op = "set_default", Clip = clip };
        static Step SetFade(float v) => new() { Op = "set_fade", Value = v };
        static Step SetTimeScale(float v) => new() { Op = "set_time_scale", Value = v };
        static Step Play(string clip, bool loop = false, float fade = -1f, float timeScale = 1f, float normalizedStart = 0f, float startTime = 0f)
            => new() { Op = "play", Clip = clip, Loop = loop, Fade = fade, TimeScale = timeScale, NormalizedStart = normalizedStart, StartTime = startTime };
        static Step Queue(string clip, bool loop = false) => new() { Op = "queue", Clip = clip, Loop = loop };
        static Step PlayBlend(float speed) => new() { Op = "play_blend", Points = new List<(string, float)>(LocoPoints), Value = speed };
        static Step SetDefaultBlend(float speed, bool play = true) => new() { Op = "set_default_blend", Points = new List<(string, float)>(LocoPoints), Value = speed, Play = play };
        static Step SetSpeed(float v) => new() { Op = "set_speed", Value = v };
        static Step Simple(string op) => new() { Op = op };
        static Step Seek(float progress) => new() { Op = "seek", Value = progress };
        static Step Register(string name, string sourceClip) => new() { Op = "register", Name = name, Clip = sourceClip };
        static Step Unregister(string name) => new() { Op = "unregister", Name = name };

        /// <summary>First frame whose Tick sees a clip of <paramref name="length"/> seconds completed.</summary>
        static int End(float length, float speed = 1f) => Mathf.CeilToInt(length / (Dt * speed));

        internal static List<Scenario> BuildScenarios(Func<string, float> len)
        {
            var list = new List<Scenario>();
            var ea = End(len("Stun"));   // Stun: one-shot present on every body (AttackCombo is weapon-package, Normal only)
            var ew = End(len("Walk"));
            var er = End(len("Run"));

            // 1. One-shot then back to the default clip (no fade).
            list.Add(new Scenario { Name = "oneshot_default" }
                .At(0, SetDefault("Idle")).At(0, Play("Stun"))
                .Sample(0, 1, 10, ea - 1, ea, ea + 1, ea + 12));

            // 2. Crossfades: loop→loop with the playable-wide fade, then a one-shot with an explicit
            //    fade, then the one-shot's return to default (fades over the clamped last frame).
            var s2 = new Scenario { Name = "fade_crossfade" }
                .At(0, SetFade(0.25f)).At(0, SetDefault("Idle")).At(0, Play("Idle", loop: true))
                .At(30, Play("Walk", loop: true))
                .Sample(30, 31, 37, 44, 45, 46, 59)
                .At(60, Play("Run", fade: 0.1f))
                .Sample(60, 61, 63, 65, 66, 67, 80);
            var runEnd = 60 + er;
            s2.Sample(runEnd - 1, runEnd, runEnd + 1, runEnd + 7, runEnd + 15, runEnd + 16, runEnd + 30);
            list.Add(s2);

            // 3. Queue chain: Walk → queued Run → (queued while Run plays) AttackCombo → default.
            var s3 = new Scenario { Name = "queue_chain" }
                .At(0, SetDefault("Idle")).At(0, Play("Walk")).At(0, Queue("Run"))
                .At(ew + 5, Queue("Stun"))
                .Sample(5, ew - 1, ew, ew + 1, ew + 10, ew + er - 1, ew + er, ew + er + 1, ew + er + ea, ew + er + ea + 1, ew + er + ea + 10);
            list.Add(s3);

            // 4. 1D blend: weights + phase-locked speeds while the parameter moves.
            list.Add(new Scenario { Name = "blend_speed" }
                .At(0, PlayBlend(0.5f))
                .At(30, SetSpeed(1.5f)).At(60, SetSpeed(2.5f)).At(80, SetSpeed(1.0f)).At(100, SetSpeed(0.25f))
                .Sample(0, 1, 15, 30, 31, 45, 60, 61, 80, 81, 100, 101, 120));

            // 5. Default blend + one-shot crossfaded in and out, then stopping the default blend.
            var s5 = new Scenario { Name = "default_blend_oneshot" }
                .At(0, SetFade(0.15f)).At(0, SetDefaultBlend(1.2f))
                .At(20, Play("Stun"))
                .Sample(19, 20, 21, 25, 28, 29, 30, 40);
            var aEnd = 20 + ea;
            s5.Sample(aEnd - 1, aEnd, aEnd + 1, aEnd + 5, aEnd + 8, aEnd + 9, aEnd + 10, aEnd + 30)
              .At(aEnd + 40, Simple("stop_blend"))
              .Sample(aEnd + 40, aEnd + 41);
            list.Add(s5);

            // 6. Pause / resume / time scales (playable-wide and per-play).
            var s6 = new Scenario { Name = "pause_timescale" }
                .At(0, SetDefault("Idle")).At(0, Play("Walk", loop: true))
                .At(10, SetTimeScale(0.5f)).At(20, Simple("pause")).At(30, Simple("resume")).At(40, SetTimeScale(2.0f))
                .At(50, Play("Run", timeScale: 1.5f)).At(55, Simple("pause")).At(60, Simple("resume"))
                .Sample(10, 11, 15, 20, 21, 25, 30, 31, 40, 41, 50, 51, 55, 56, 60, 61, 70);
            var runFast = 50 + End(len("Run"), 3f) + 5;   // 5 paused frames
            s6.Sample(runFast - 1, runFast, runFast + 1, runFast + 10).At(runFast + 15, SetTimeScale(1f)).Sample(runFast + 16, runFast + 25);
            list.Add(s6);

            // 7. Interrupt: with a queued clip (plays it) and without (default), then Stop.
            list.Add(new Scenario { Name = "interrupt_queued" }
                .At(0, SetDefault("Idle")).At(0, Play("Walk")).At(0, Queue("Run", loop: true))
                .At(15, Simple("interrupt")).At(50, Simple("interrupt")).At(70, Simple("stop"))
                .Sample(14, 15, 16, 30, 49, 50, 51, 65, 69, 70, 71, 80));

            // 8. Start offsets, seek, Complete().
            list.Add(new Scenario { Name = "start_seek_complete" }
                .At(0, SetDefault("Idle")).At(0, Play("Walk", loop: true, normalizedStart: 0.5f))
                .At(10, Play("Run", startTime: 0.2f)).At(20, Seek(0.1f)).At(30, Simple("complete"))
                .Sample(0, 1, 9, 10, 11, 19, 20, 21, 29, 30, 31, 45));

            // 9. User-registered clips shadow body clips; unregister restores them.
            var s9 = new Scenario { Name = "user_clip" }
                .At(0, Register("Idle", "Run")).At(0, Register("Custom", "Walk"))
                .At(0, SetDefault("Idle")).At(0, Play("Custom", loop: true))
                .At(20, Play("Stun"))
                .Sample(1, 10, 20, 21, aEnd - 1, aEnd, aEnd + 1, aEnd + 10)
                .At(aEnd + 15, Unregister("Idle")).At(aEnd + 16, Simple("interrupt"))
                .Sample(aEnd + 16, aEnd + 17, aEnd + 30);
            list.Add(s9);

            // 10. Weapon-package clip through the playable (SwordAttack one-shot → default).
            var es = End(len("SwordAttack"));
            if (es > 0)
            {
                list.Add(new Scenario { Name = "weapon_oneshot" }
                    .At(0, SetDefault("Idle")).At(0, Play("SwordAttack"))
                    .Sample(1, 12, es - 1, es, es + 1, es + 10));
            }
            return list;
        }

        // -------------------------------------------------------------------------
        // Runner (Play mode)
        // -------------------------------------------------------------------------

        internal sealed class Fixture
        {
            public string Name;
            public AxieDescriptor Descriptor;
        }

        internal static List<Fixture> BuildFixtures() => new()
        {
            new Fixture { Name = "beast02_s00_normal", Descriptor = AxieGltfExporter.MakeDescriptor(AxieBodyType.Normal, 3, "Beast", 2, 0, 1) },
            new Fixture { Name = "aquatic04_s00_frosty", Descriptor = AxieGltfExporter.MakeDescriptor(AxieBodyType.Frosty, 48, "Aquatic", 4, 0, 1) },
        };
    }

    /// <summary>Runs before <c>AxieAnimatorUpdater</c> (order 0) so a frame's steps precede that frame's Tick.</summary>
    [DefaultExecutionOrder(-500)]
    internal sealed class AxiePlayableOracleRunner : MonoBehaviour
    {
        AxieFactory _factory;
        AxieFactory _previousDefault;
        AxieWeaponAnimCatalog _weaponCatalog;
        List<AxiePlayableOracle.Fixture> _fixtures;
        int _fixtureIndex = -1;
        List<AxiePlayableOracle.Scenario> _scenarios;
        int _scenarioIndex = -1;

        AxieCharacter3D _character;
        AxiePlayable _playable;
        List<Transform> _transforms;
        AxiePlayableOracle.Scenario _scenario;
        int _frame = -1;
        AnimTrack _lastTrack;
        AnimBlend _lastBlend;
        readonly List<(int frame, string clip)> _events = new();
        readonly List<(int frame, string file)> _written = new();
        readonly Dictionary<string, float> _clipLengths = new();
        AxieGltfExporter.JsonWriter _index;
        StreamWriter _indexStream;
        bool _indexFixtureOpen;
        bool _done;

        void Awake()
        {
            try
            {
                _factory = AssetDatabase.LoadAssetAtPath<AxieFactory>(AxieGltfExporter.CatalogPath);
                if (_factory == null)
                    foreach (var guid in AssetDatabase.FindAssets("t:AxieFactory"))
                    {
                        _factory = AssetDatabase.LoadAssetAtPath<AxieFactory>(AssetDatabase.GUIDToAssetPath(guid));
                        if (_factory != null) break;
                    }
                if (_factory == null) throw new InvalidOperationException("No AxieFactory catalog asset found.");
                _previousDefault = AxieFactory.Default;
                AxieFactory.Default = _factory;
                _weaponCatalog = AxieGltfExporter.FindWeaponCatalog();
                if (_weaponCatalog != null) AxieWeaponAnims.Register(_weaponCatalog, _factory);

                _fixtures = AxiePlayableOracle.BuildFixtures();
                _indexStream = new StreamWriter(Path.Combine(AxiePlayableOracle.OutDir, "index.json"), false, new UTF8Encoding(false));
                _index = new AxieGltfExporter.JsonWriter(_indexStream);
                _index.BeginObject();
                _index.Key("format_version"); _index.Value(AxiePlayableOracle.FormatVersion);
                _index.Key("space"); _index.Value("godot_right_handed_mirrored_x_world");
                _index.Key("dt"); _index.Value(AxiePlayableOracle.Dt);
                _index.Key("fixtures");
                _index.BeginArray();
            }
            catch (Exception ex)
            {
                Fail(ex);
            }
        }

        void Fail(Exception ex)
        {
            Debug.LogError($"[AxiePlayableOracle] FAILED: {ex}");
            AxiePlayableOracle.Failed = true;
            Finish();
        }

        void Finish()
        {
            if (_done) return;
            _done = true;
            try
            {
                DisposeCharacter();
                if (_index != null)
                {
                    if (_indexFixtureOpen) { _index.EndArray(); _index.EndObject(); _indexFixtureOpen = false; }
                    _index.EndArray();
                    _index.EndObject();
                    _index.Dispose();
                    _indexStream.Dispose();
                }
                if (_weaponCatalog != null) AxieWeaponAnims.Unregister(_weaponCatalog, _factory);
                AxieFactory.Default = _previousDefault;
            }
            catch (Exception ex)
            {
                Debug.LogError($"[AxiePlayableOracle] teardown: {ex}");
                AxiePlayableOracle.Failed = true;
            }
            EditorApplication.ExitPlaymode();
        }

        void DisposeCharacter()
        {
            if (_playable != null) _playable.Completed -= OnCompleted;
            _character?.Dispose();
            _character = null;
            _playable = null;
            _scenario = null;
        }

        void OnCompleted(string clip) => _events.Add((_frame, clip));

        // Steps for this frame, then the character's AxieAnimatorUpdater ticks (order 0), then the
        // Animator evaluates the graph, then LateUpdate samples.
        void Update()
        {
            if (_done || AxiePlayableOracle.Failed) return;
            if (_scenario == null) return;   // set up during the previous LateUpdate; first tick next frame
            try
            {
                foreach (var s in _scenario.Steps)
                    if (s.Frame == _frame) Apply(s);
            }
            catch (Exception ex) { Fail(ex); }
        }

        void LateUpdate()
        {
            if (_done || AxiePlayableOracle.Failed) return;
            try
            {
                if (_scenario != null)
                {
                    if (_scenario.SampleFrames.Contains(_frame)) WriteSample();
                    if (_frame >= _scenario.LastFrame) EndScenario();
                    else _frame++;
                }
                if (_scenario == null && !StartNext()) Finish();
            }
            catch (Exception ex) { Fail(ex); }
        }

        bool StartNext()
        {
            while (true)
            {
                if (_fixtureIndex < 0 || _scenarios == null || _scenarioIndex + 1 >= _scenarios.Count)
                {
                    if (_indexFixtureOpen) { _index.EndArray(); _index.EndObject(); _indexFixtureOpen = false; }
                    _fixtureIndex++;
                    if (_fixtureIndex >= _fixtures.Count) return false;
                    var fx = _fixtures[_fixtureIndex];
                    var probe = _factory.CreateCharacter(fx.Descriptor, new AxieInstantiationParams { combineMeshes = false });
                    if (probe == null) { Debug.LogWarning($"[AxiePlayableOracle] cannot build {fx.Name}"); _scenarios = null; continue; }
                    _clipLengths.Clear();
                    foreach (var n in new[] { "Idle", "Walk", "Run", "Stun", "Stun", "Dead", "SwordAttack" })
                    {
                        var c = probe.GetAnimClip(n);
                        if (c != null) _clipLengths[n] = c.length;
                    }
                    probe.Dispose();
                    _scenarios = AxiePlayableOracle.BuildScenarios(n => _clipLengths.TryGetValue(n, out var l) ? l : 0f);
                    _scenarioIndex = -1;
                    _index.BeginObject();
                    _index.Key("name"); _index.Value(fx.Name);
                    _index.Key("body"); _index.Value(fx.Descriptor.body.ToString());
                    _index.Key("color_variant"); _index.Value(fx.Descriptor.colorVariant);
                    _index.Key("parts");
                    _index.BeginArray();
                    foreach (var part in fx.Descriptor.parts)
                    {
                        _index.BeginObject();
                        _index.Key("type"); _index.Value(part.type.ToString());
                        _index.Key("class"); _index.Value(part.@class);
                        _index.Key("variant"); _index.Value(part.variant);
                        _index.Key("skin"); _index.Value(part.skin);
                        _index.Key("level"); _index.Value(part.level);
                        _index.EndObject();
                    }
                    _index.EndArray();
                    _index.Key("clip_lengths");
                    _index.BeginObject();
                    foreach (var kv in _clipLengths) { _index.Key(kv.Key); _index.Value(kv.Value); }
                    _index.EndObject();
                    _index.Key("scenarios");
                    _index.BeginArray();
                    _indexFixtureOpen = true;
                }
                _scenarioIndex++;
                var fixture = _fixtures[_fixtureIndex];
                var scenario = _scenarios[_scenarioIndex];
                _character = _factory.CreateCharacter(fixture.Descriptor, new AxieInstantiationParams { combineMeshes = false });
                if (_character == null) throw new InvalidOperationException($"factory returned no character for {fixture.Name}");
                _character.Root.name = fixture.Name;
                _playable = _character.Playable;   // creates the Animator + updater now, before frame 0
                var animator = _character.Root.GetComponent<Animator>();
                if (animator != null) animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
                _playable.Completed += OnCompleted;
                _transforms = new List<Transform>();
                AxieGltfExporter.CollectDepthFirst(_character.Root.transform, _transforms);
                _events.Clear();
                _written.Clear();
                _lastTrack = null;
                _lastBlend = null;
                _scenario = scenario;
                _frame = 0;
                Directory.CreateDirectory(Path.Combine(AxiePlayableOracle.OutDir, fixture.Name));
                return true;
            }
        }

        void EndScenario()
        {
            var fixture = _fixtures[_fixtureIndex];
            _index.BeginObject();
            _index.Key("name"); _index.Value(_scenario.Name);
            _index.Key("dir"); _index.Value(fixture.Name);
            _index.Key("steps");
            _index.BeginArray();
            foreach (var s in _scenario.Steps) WriteStep(_index, s);
            _index.EndArray();
            _index.Key("samples");
            _index.BeginArray();
            foreach (var (frame, file) in _written)
            {
                _index.BeginObject();
                _index.Key("frame"); _index.Value(frame);
                _index.Key("file"); _index.Value(file);
                _index.EndObject();
            }
            _index.EndArray();
            _index.Key("completed");
            _index.BeginArray();
            foreach (var (frame, clip) in _events)
            {
                _index.BeginObject();
                _index.Key("frame"); _index.Value(frame);
                _index.Key("clip"); _index.Value(clip ?? "");
                _index.EndObject();
            }
            _index.EndArray();
            _index.EndObject();
            Debug.Log($"[AxiePlayableOracle] {fixture.Name}/{_scenario.Name}: {_written.Count} samples, {_events.Count} completions");
            DisposeCharacter();
        }

        static void WriteStep(AxieGltfExporter.JsonWriter j, AxiePlayableOracle.Step s)
        {
            j.BeginObject();
            j.Key("frame"); j.Value(s.Frame);
            j.Key("op"); j.Value(s.Op);
            switch (s.Op)
            {
                case "set_default":
                    j.Key("clip"); j.Value(s.Clip);
                    break;
                case "set_fade":
                case "set_time_scale":
                case "set_speed":
                case "seek":
                    j.Key("value"); j.Value(s.Value);
                    break;
                case "play":
                    j.Key("clip"); j.Value(s.Clip);
                    j.Key("loop"); j.Value(s.Loop);
                    j.Key("fade"); j.Value(s.Fade);
                    j.Key("time_scale"); j.Value(s.TimeScale);
                    j.Key("normalized_start"); j.Value(s.NormalizedStart);
                    j.Key("start_time"); j.Value(s.StartTime);
                    break;
                case "queue":
                    j.Key("clip"); j.Value(s.Clip);
                    j.Key("loop"); j.Value(s.Loop);
                    break;
                case "play_blend":
                case "set_default_blend":
                    j.Key("points");
                    j.BeginArray();
                    foreach (var (clip, threshold) in s.Points)
                    {
                        j.BeginArray(); j.Value(clip); j.Value(threshold); j.EndArray();
                    }
                    j.EndArray();
                    j.Key("speed"); j.Value(s.Value);
                    if (s.Op == "set_default_blend") { j.Key("play"); j.Value(s.Play); }
                    break;
                case "register":
                    j.Key("name"); j.Value(s.Name);
                    j.Key("source_clip"); j.Value(s.Clip);
                    break;
                case "unregister":
                    j.Key("name"); j.Value(s.Name);
                    break;
            }
            j.EndObject();
        }

        void Apply(AxiePlayableOracle.Step s)
        {
            switch (s.Op)
            {
                case "set_default": _playable.SetDefault(s.Clip); break;
                case "set_fade": _playable.Fade = s.Value; break;
                case "set_time_scale": _playable.TimeScale = s.Value; break;
                case "play":
                    _lastTrack = _playable.Play(new AnimPlayParams
                    {
                        ClipName = s.Clip, Loop = s.Loop, Fade = s.Fade, TimeScale = s.TimeScale,
                        NormalizedStart = s.NormalizedStart, StartTime = s.StartTime,
                    });
                    if (_lastTrack == null) throw new InvalidOperationException($"Play({s.Clip}) returned null");
                    break;
                case "queue":
                    _playable.Queue(new AnimPlayParams { ClipName = s.Clip, Loop = s.Loop });
                    break;
                case "play_blend":
                    _lastBlend = _playable.PlayBlend(s.Points, s.Value);
                    if (_lastBlend == null) throw new InvalidOperationException("PlayBlend returned null");
                    break;
                case "set_default_blend":
                    _lastBlend = _playable.SetDefaultBlend(s.Points, s.Value, s.Play);
                    if (_lastBlend == null) throw new InvalidOperationException("SetDefaultBlend returned null");
                    break;
                case "set_speed": _playable.SetSpeed(s.Value); break;
                case "interrupt": _playable.Interrupt(); break;
                case "pause": _playable.Pause(); break;
                case "resume": _playable.Resume(); break;
                case "stop": _playable.Stop(); break;
                case "stop_blend": (_playable.CurrentBlend ?? _lastBlend)?.Stop(); break;
                case "seek": if (_lastTrack != null) _lastTrack.Progress = s.Value; break;
                case "complete": _lastTrack?.Complete(); break;
                case "register":
                    {
                        var clip = _character.GetAnimClip(s.Clip);
                        if (clip == null) throw new InvalidOperationException($"register: no body clip {s.Clip}");
                        _playable.Register(s.Name, clip);
                        break;
                    }
                case "unregister": _playable.Unregister(s.Name); break;
                default: throw new InvalidOperationException($"unknown op {s.Op}");
            }
        }

        void WriteSample()
        {
            var fixture = _fixtures[_fixtureIndex];
            var file = $"{_scenario.Name}_f{_frame.ToString("0000", CultureInfo.InvariantCulture)}.json";
            var path = Path.Combine(AxiePlayableOracle.OutDir, fixture.Name, file);
            var root = _character.Root;
            using var sw = new StreamWriter(path, false, new UTF8Encoding(false));
            using var j = new AxieGltfExporter.JsonWriter(sw);
            j.BeginObject();
            j.Key("scenario"); j.Value(_scenario.Name);
            j.Key("frame"); j.Value(_frame);
            j.Key("time"); j.Value((_frame + 1) * AxiePlayableOracle.Dt);
            j.Key("state");
            j.BeginObject();
            var track = _playable.CurrentTrack;
            j.Key("is_playing"); j.Value(_playable.IsPlaying);
            j.Key("is_paused"); j.Value(_playable.IsPaused);
            j.Key("track"); j.Value(track?.ClipName ?? "");
            j.Key("track_loop"); j.Value(track?.Loop ?? false);
            j.Key("progress"); j.Value(track?.Progress ?? 0f);
            j.Key("blend_active"); j.Value(_playable.CurrentBlend != null);
            j.Key("blend_speed"); j.Value(_playable.Speed);
            j.Key("default_clip"); j.Value(_playable.DefaultClipName ?? "");
            j.EndObject();
            j.Key("nodes");
            j.BeginArray();
            var rootInv = root.transform.worldToLocalMatrix;
            foreach (var tr in _transforms)
            {
                if (tr == null) continue;
                var m = AxieGltfExporter.MM(rootInv * tr.localToWorldMatrix);
                j.BeginObject();
                j.Key("path"); j.Value(AxieGltfExporter.PathFrom(root.transform, tr));
                j.Key("name"); j.Value(tr.name);
                j.Key("matrix");
                j.BeginArray();
                for (var c = 0; c < 4; c++)
                    for (var r = 0; r < 4; r++)
                        j.Value(m[r, c]);
                j.EndArray();
                j.EndObject();
            }
            j.EndArray();
            j.EndObject();
            _written.Add((_frame, file));
        }
    }
}
