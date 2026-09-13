using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using SkyMavis.AxieMixer3D;
using SkyMavis.AxieMixer3D.WeaponAnims;
using UnityEditor;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;
using UnityEngine.Rendering;

namespace SkyMavis.AxieMixer3D.Dev.Editor
{
    /// <summary>
    /// Batchmode exporter v2: Unity Axie Mixer 3D catalog → glTF 2.0 (.glb) asset pack for the Godot port.
    ///
    /// One .glb per body prefab (node hierarchy, skin, skinned mesh, every locomotion clip baked by
    /// Mecanim's PlayableGraph evaluator at AXIE_GODOT_BAKE_MULT × the clip frame rate), one .glb per part rig prefab (own joint chain +
    /// skinned mesh), one animation-only .glb per body for the optional weapon package, plus materials,
    /// textures, particle-system dumps for addon (mystic) prefabs, and a JSON catalog.
    ///
    /// All geometry is converted from Unity left-handed to glTF right-handed by mirroring X once here.
    /// Godot's native glTF importer does the rest.
    ///
    /// Invoke:
    ///   -executeMethod SkyMavis.AxieMixer3D.Dev.Editor.AxieGltfExporter.Export
    /// Env:
    ///   AXIE_GODOT_ASSETS_DIR  output pack dir (default: <godot repo>/addons/axie_mixer_3d_assets)
    ///   AXIE_GODOT_ORACLE_DIR  numeric oracle dir (default: <godot repo>/tests/oracle)
    ///   AXIE_GODOT_RENDER_DIR  render oracle dir (default: <godot repo>/tests/render_oracle)
    ///   AXIE_GODOT_EXPORT_ONLY comma list of stages to run: pack,oracle,render (default pack,oracle;
    ///                          render needs a graphics device, i.e. batchmode without -nographics)
    ///   AXIE_GODOT_SAMPLE_JSON path of sample_axies.json (genes for live IDs) for the oracle
    /// </summary>
    public static class AxieGltfExporter
    {
        /// <summary>
        /// Root of the Godot repository. `AXIE_GODOT_REPO`, else a `godot-axie-mixer-3d` checkout next
        /// to this Unity project. Every `AXIE_GODOT_*_DIR` variable overrides its own path.
        /// </summary>
        public static readonly string GodotRepo = Path.GetFullPath(Env("AXIE_GODOT_REPO", Path.Combine(Directory.GetCurrentDirectory(), "..", "godot-axie-mixer-3d")));
        public static readonly string DefaultAssetsDir = GodotRepo + "/addons/axie_mixer_3d_assets";
        public static readonly string DefaultOracleDir = GodotRepo + "/tests/oracle";
        public static readonly string DefaultRenderDir = GodotRepo + "/tests/render_oracle";
        public static readonly string DefaultSampleJson = GodotRepo + "/tests/goldens/sample_axies.json";
        public const int PackFormatVersion = 2;

        internal const string CatalogPath = "Packages/com.skymavis.axiemixer3d/AxieMixerAssets/AxieFactory.asset";

        static readonly Regex AttachPointRegex = new(@"^Root_(?<rigType>\w+)_JNT$", RegexOptions.Compiled);
        static readonly HashSet<string> SkippedTextureProps = new(StringComparer.Ordinal)
        {
            "unity_Lightmaps", "unity_LightmapsInd", "unity_ShadowMasks",
        };

        // Mirror across the YZ plane: Unity LH (Y up, +Z forward) → glTF RH (Y up, +Z front).
        static readonly Matrix4x4 MirrorX = Matrix4x4.Scale(new Vector3(-1f, 1f, 1f));

        static Vector3 MV(Vector3 v) => new(-v.x, v.y, v.z);
        static Quaternion MQ(Quaternion q) => new(q.x, -q.y, -q.z, q.w);
        internal static Matrix4x4 MM(Matrix4x4 m) => MirrorX * m * MirrorX;

        // -------------------------------------------------------------------------
        // Entry points
        // -------------------------------------------------------------------------

        [MenuItem("Tools/Axie Mixer 3D/Export glTF pack for Godot", priority = 90)]
        public static void Export()
        {
            var assetsDir = Env("AXIE_GODOT_ASSETS_DIR", DefaultAssetsDir);
            var oracleDir = Env("AXIE_GODOT_ORACLE_DIR", DefaultOracleDir);
            var renderDir = Env("AXIE_GODOT_RENDER_DIR", DefaultRenderDir);
            var only = Env("AXIE_GODOT_EXPORT_ONLY", "pack,oracle");
            try
            {
                var factory = AssetDatabase.LoadAssetAtPath<AxieFactory>(CatalogPath);
                if (factory == null)
                {
                    foreach (var guid in AssetDatabase.FindAssets("t:AxieFactory"))
                    {
                        factory = AssetDatabase.LoadAssetAtPath<AxieFactory>(AssetDatabase.GUIDToAssetPath(guid));
                        if (factory != null) break;
                    }
                }
                if (factory == null) throw new InvalidOperationException("No AxieFactory catalog asset found.");

                if (only.Contains("pack")) RunPack(Path.GetFullPath(assetsDir), factory);
                if (only.Contains("oracle")) RunOracle(Path.GetFullPath(oracleDir), factory);
                if (only.Contains("render")) RunRenders(Path.GetFullPath(renderDir), factory);
                Debug.Log("[AxieGltfExporter] DONE");
            }
            catch (Exception ex)
            {
                Debug.LogError($"[AxieGltfExporter] FAILED: {ex}");
                if (Application.isBatchMode) { EditorApplication.Exit(1); return; }
                throw;
            }
        }

        /// <summary>Sub-frame animation bake factor (`AXIE_GODOT_BAKE_MULT`, default 4 → 120 samples/s).</summary>
        internal static int BakeMult => Mathf.Max(1, int.Parse(Env("AXIE_GODOT_BAKE_MULT", "4")));

        internal static string Env(string key, string fallback)
        {
            var v = Environment.GetEnvironmentVariable(key);
            return string.IsNullOrWhiteSpace(v) ? fallback : v;
        }

        // -------------------------------------------------------------------------
        // Asset pack
        // -------------------------------------------------------------------------

        static void RunPack(string outDir, AxieFactory factory)
        {
            Debug.Log($"[AxieGltfExporter] pack → {outDir}");
            var bodies = ReadField<AxieBodyEntry[]>(factory, "_bodies") ?? Array.Empty<AxieBodyEntry>();
            var parts = ReadField<AxiePartEntry[]>(factory, "_parts") ?? Array.Empty<AxiePartEntry>();
            var addons = ReadField<AxieAddonEntry[]>(factory, "_addons") ?? Array.Empty<AxieAddonEntry>();
            var colors = ReadField<AxieColorVariant[]>(factory, "_colors") ?? Array.Empty<AxieColorVariant>();
            var defaults = ReadField<AxieInstantiationParams>(factory, "_defaultInstantiationParams");

            Directory.CreateDirectory(outDir);
            foreach (var sub in new[] { "bodies", "parts", "weapon_anims", "materials", "textures", "addons" })
            {
                var p = Path.Combine(outDir, sub);
                if (Directory.Exists(p)) Directory.Delete(p, true);
                Directory.CreateDirectory(p);
            }

            var ctx = new ExportContext();
            var cat = new StringBuilder();
            using var j = new JsonWriter(new StringWriter(cat));
            j.BeginObject();
            j.Key("format_version"); j.Value(PackFormatVersion);
            j.Key("source_catalog"); j.Value(AssetDatabase.GetAssetPath(factory));
            j.Key("package_version"); j.Value(AxieMixer3DVersion.Version);
            j.Key("coordinate_system");
            j.BeginObject();
            j.Key("source"); j.Value("unity_left_handed_y_up");
            j.Key("pack"); j.Value("gltf_right_handed_y_up_mirrored_x");
            j.Key("front"); j.Value("+Z");
            j.EndObject();

            j.Key("default_instantiation_params");
            j.BeginObject();
            j.Key("combine_meshes"); j.Value(defaults == null || defaults.combineMeshes);
            j.EndObject();

            // Clip sample rate of the baked glTF animations (clip frame rate × AXIE_GODOT_BAKE_MULT).
            // Godot's glTF importer re-bakes every TRS track at GLTFState.bake_fps; the addon sets it
            // to this value so no sample is dropped (docs/design.md §4).
            j.Key("animation_fps"); j.Value(30 * BakeMult);

            // ---- bodies
            var weaponCatalog = FindWeaponCatalog();
            j.Key("bodies");
            j.BeginArray();
            foreach (var entry in bodies)
            {
                if (entry.data == null || entry.data.prefab == null) continue;
                var bodyName = entry.type.ToString();
                var clips = new List<KeyValuePair<string, AnimationClip>>();
                if (entry.data.animations != null)
                {
                    foreach (var a in entry.data.animations)
                        if (a != null && a.clip != null && !string.IsNullOrEmpty(a.name))
                            clips.Add(new KeyValuePair<string, AnimationClip>(NormalizeClipName(a.name), a.clip));
                }
                var glbRel = $"bodies/{bodyName}.glb";
                var info = ExportPrefabGlb(entry.data.prefab, clips, Path.Combine(outDir, glbRel), true, ctx);
                Debug.Log($"[AxieGltfExporter] body {bodyName}: nodes={info.NodeCount} joints={info.JointCount} verts={info.VertexCount} clips={clips.Count}");

                j.BeginObject();
                j.Key("type"); j.Value(bodyName);
                j.Key("glb"); j.Value(glbRel);
                j.Key("animations");
                j.BeginArray();
                foreach (var c in clips) j.Value(c.Key);
                j.EndArray();
                j.Key("materials");
                j.BeginArray();
                foreach (var m in info.MaterialIds) j.Value(m);
                j.EndArray();
                j.Key("attach_points");
                j.BeginArray();
                foreach (var ap in info.AttachPoints) j.Value(ap);
                j.EndArray();

                // Weapon clips: animation-only glb.
                var weaponClips = CollectWeaponClips(weaponCatalog, entry.type);
                if (weaponClips.Count > 0)
                {
                    // Includes the (small) body skin so Godot builds the identical Skeleton3D and the
                    // imported tracks resolve to the same bone paths as the locomotion glb.
                    var wRel = $"weapon_anims/{bodyName}.glb";
                    ExportPrefabGlb(entry.data.prefab, weaponClips, Path.Combine(outDir, wRel), true, ctx);
                    Debug.Log($"[AxieGltfExporter] weapon anims {bodyName}: clips={weaponClips.Count}");
                    j.Key("weapon_anims_glb"); j.Value(wRel);
                    j.Key("weapon_animations");
                    j.BeginArray();
                    foreach (var c in weaponClips) j.Value(c.Key);
                    j.EndArray();
                }
                j.EndObject();
            }
            j.EndArray();

            // ---- parts
            j.Key("parts");
            j.BeginObject();
            var partCount = 0;
            var rigCount = 0;
            foreach (var entry in parts)
            {
                if (string.IsNullOrEmpty(entry.name) || entry.rigs == null) continue;
                partCount++;
                j.Key(entry.name);
                j.BeginObject();
                j.Key("rigs");
                j.BeginArray();
                foreach (var rig in entry.rigs)
                {
                    if (rig == null || rig.prefab == null) continue;
                    rigCount++;
                    var rigName = rig.type.ToString();
                    var glbRel = $"parts/{entry.name}_{rigName}.glb";
                    var info = ExportPrefabGlb(rig.prefab, null, Path.Combine(outDir, glbRel), true, ctx);
                    j.BeginObject();
                    j.Key("type"); j.Value(rigName);
                    j.Key("glb"); j.Value(glbRel);
                    j.Key("prefab_name"); j.Value(rig.prefab.name);
                    j.Key("materials");
                    j.BeginArray();
                    foreach (var m in info.MaterialIds) j.Value(m);
                    j.EndArray();
                    j.EndObject();
                }
                j.EndArray();
                j.EndObject();
            }
            j.EndObject();
            Debug.Log($"[AxieGltfExporter] parts={partCount} rigs={rigCount}");

            // ---- addons (mystic)
            j.Key("addons");
            j.BeginObject();
            var addonCount = 0;
            foreach (var entry in addons)
            {
                if (entry == null || string.IsNullOrEmpty(entry.name)) continue;
                addonCount++;
                j.Key(entry.name);
                j.BeginObject();
                j.Key("materials");
                j.BeginArray();
                if (entry.materials != null)
                {
                    foreach (var am in entry.materials)
                    {
                        if (am.material == null) continue;
                        ctx.EnqueueMaterial(am.material);
                        j.BeginObject();
                        j.Key("name"); j.Value(string.IsNullOrEmpty(am.name) ? am.material.name : am.name);
                        j.Key("material"); j.Value(ctx.Id(am.material));
                        j.EndObject();
                    }
                }
                j.EndArray();
                j.Key("prefabs");
                j.BeginArray();
                if (entry.prefabs != null)
                {
                    foreach (var go in entry.prefabs)
                    {
                        if (go == null) continue;
                        var rel = $"addons/{Sanitize(entry.name)}__{Sanitize(go.name)}.json";
                        ExportAddonPrefab(go, Path.Combine(outDir, rel), ctx);
                        j.Value(rel);
                    }
                }
                j.EndArray();
                j.EndObject();
            }
            j.EndObject();
            Debug.Log($"[AxieGltfExporter] addons={addonCount}");

            // ---- colors
            j.Key("colors");
            j.BeginArray();
            foreach (var c in colors)
            {
                j.BeginObject();
                j.Key("index"); j.Value(c.index);
                j.Key("key"); j.Value(c.key ?? "");
                j.Key("skin"); j.Value(c.skin);
                j.Key("class"); j.Value(c.@class ?? "");
                j.Key("color_value"); j.Value(c.color_value);
                j.Key("primary1"); j.Value(c.primary1 ?? "");
                j.Key("primary2"); j.Value(c.primary2 ?? "");
                j.EndObject();
            }
            j.EndArray();
            j.EndObject();
            j.Dispose();

            // ---- materials + textures
            foreach (var mat in new List<Material>(ctx.Materials.Values))
                WriteMaterial(outDir, ctx, mat);
            using (var tj = new JsonWriter(new StreamWriter(Path.Combine(outDir, "textures.json"), false, new UTF8Encoding(false))))
            {
                tj.BeginObject();
                foreach (var kv in ctx.Textures)
                    WriteTexture(outDir, kv.Key, kv.Value, tj);
                tj.EndObject();
            }

            File.WriteAllText(Path.Combine(outDir, "catalog.json"), cat.ToString(), new UTF8Encoding(false));
            Debug.Log($"[AxieGltfExporter] materials={ctx.Materials.Count} textures={ctx.Textures.Count} wrote {outDir}/catalog.json");
        }

        static string NormalizeClipName(string name)
        {
            var bare =
                name.StartsWith("Default.", StringComparison.OrdinalIgnoreCase) ? name.Substring(8) :
                name.StartsWith("Action.", StringComparison.OrdinalIgnoreCase) ? name.Substring(7) :
                name;
            if (bare.StartsWith("Canon", StringComparison.Ordinal) && !bare.StartsWith("Cannon", StringComparison.Ordinal))
                bare = "Cannon" + bare.Substring("Canon".Length);
            return bare;
        }

        internal static AxieWeaponAnimCatalog FindWeaponCatalog()
        {
            try
            {
                foreach (var guid in AssetDatabase.FindAssets("t:AxieWeaponAnimCatalog"))
                {
                    var cat = AssetDatabase.LoadAssetAtPath<AxieWeaponAnimCatalog>(AssetDatabase.GUIDToAssetPath(guid));
                    if (cat != null) return cat;
                }
            }
            catch (Exception ex)
            {
                Debug.LogWarning($"[AxieGltfExporter] weapon catalog lookup failed: {ex.Message}");
            }
            return null;
        }

        static List<KeyValuePair<string, AnimationClip>> CollectWeaponClips(AxieWeaponAnimCatalog cat, AxieBodyType body)
        {
            var list = new List<KeyValuePair<string, AnimationClip>>();
            if (cat == null || cat.bodies == null) return list;
            foreach (var b in cat.bodies)
            {
                if (b == null || b.body != body || b.animations == null) continue;
                foreach (var e in b.animations)
                    if (e != null && e.clip != null && !string.IsNullOrEmpty(e.name))
                        list.Add(new KeyValuePair<string, AnimationClip>(NormalizeClipName(e.name), e.clip));
            }
            return list;
        }

        // -------------------------------------------------------------------------
        // Prefab → glb
        // -------------------------------------------------------------------------

        class PrefabInfo
        {
            public int NodeCount;
            public int JointCount;
            public int VertexCount;
            public List<string> MaterialIds = new();
            public List<string> AttachPoints = new();
        }

        struct RestTrs
        {
            public Vector3 P;
            public Quaternion R;
            public Vector3 S;
        }

        /// <summary>
        /// Instantiate the prefab, write its Transform hierarchy as glTF nodes, its SkinnedMeshRenderers as
        /// skinned meshes (when includeMesh), and each clip baked at the clip's frame rate as a glTF animation.
        /// </summary>
        static PrefabInfo ExportPrefabGlb(GameObject prefab, List<KeyValuePair<string, AnimationClip>> clips, string outPath, bool includeMesh, ExportContext ctx)
        {
            var info = new PrefabInfo();
            var root = (GameObject)PrefabUtility.InstantiatePrefab(prefab);
            if (root == null) root = UnityEngine.Object.Instantiate(prefab);
            try
            {
                root.name = prefab.name;
                var g = new GltfBuilder(Path.GetFileNameWithoutExtension(outPath));

                // Transforms in deterministic depth-first order (parents before children).
                var transforms = new List<Transform>();
                CollectDepthFirst(root.transform, transforms);
                var nodeIndex = new Dictionary<Transform, int>(transforms.Count);
                var rest = new RestTrs[transforms.Count];
                for (var i = 0; i < transforms.Count; i++)
                {
                    var t = transforms[i];
                    nodeIndex[t] = i;
                    rest[i] = new RestTrs { P = t.localPosition, R = t.localRotation, S = t.localScale };
                    g.AddNode(t.name, MV(t.localPosition), MQ(t.localRotation), t.localScale);
                    if (AttachPointRegex.IsMatch(t.name)) info.AttachPoints.Add(t.name);
                }
                for (var i = 0; i < transforms.Count; i++)
                {
                    var t = transforms[i];
                    if (t.parent != null && nodeIndex.TryGetValue(t.parent, out var pi))
                        g.AddChild(pi, i);
                }
                g.SetSceneRoot(0);
                info.NodeCount = transforms.Count;

                // Renderer nodes (and their pure-container ancestors) are not joints; everything else is.
                var rendererNodes = new HashSet<Transform>();
                var smrs = root.GetComponentsInChildren<SkinnedMeshRenderer>(true);
                foreach (var smr in smrs) rendererNodes.Add(smr.transform);
                foreach (var mr in root.GetComponentsInChildren<MeshRenderer>(true)) rendererNodes.Add(mr.transform);

                var jointSet = new HashSet<Transform>();
                foreach (var t in transforms)
                {
                    if (t == root.transform) continue;
                    if (rendererNodes.Contains(t)) continue;
                    if (IsPureContainerOfRenderers(t, rendererNodes)) continue;
                    jointSet.Add(t);
                }
                // Also every bone referenced by any SMR (safety).
                foreach (var smr in smrs)
                    foreach (var b in smr.bones) if (b != null && b != root.transform) jointSet.Add(b);
                info.JointCount = jointSet.Count;

                // Joint list in hierarchy order: SMR bones first (so JOINTS_0 = Unity bone index), then the rest.
                var jointOrder = new List<Transform>();
                if (smrs.Length > 0 && smrs[0].bones != null)
                    foreach (var b in smrs[0].bones) if (b != null && !jointOrder.Contains(b)) jointOrder.Add(b);
                foreach (var t in transforms) if (jointSet.Contains(t) && !jointOrder.Contains(t)) jointOrder.Add(t);

                if (includeMesh && smrs.Length > 0)
                {
                    // One skin shared by the prefab (all SMRs of a part/body reference the same joint set).
                    var ibms = new Matrix4x4[jointOrder.Count];
                    var primarySmr = smrs[0];
                    var primaryBones = primarySmr.bones;
                    var primaryBind = primarySmr.sharedMesh != null ? primarySmr.sharedMesh.bindposes : Array.Empty<Matrix4x4>();
                    for (var i = 0; i < jointOrder.Count; i++)
                    {
                        var jt = jointOrder[i];
                        var idx = Array.IndexOf(primaryBones, jt);
                        Matrix4x4 bind;
                        if (idx >= 0 && idx < primaryBind.Length) bind = primaryBind[idx];
                        else bind = jt.worldToLocalMatrix * primarySmr.transform.localToWorldMatrix;
                        ibms[i] = MM(bind);
                    }
                    var jointNodes = new int[jointOrder.Count];
                    for (var i = 0; i < jointOrder.Count; i++) jointNodes[i] = nodeIndex[jointOrder[i]];
                    // glTF skin.skeleton = the single top-most joint (all joints descend from it), else omitted.
                    Transform top = null;
                    var tops = 0;
                    foreach (var jt in jointOrder)
                    {
                        if (jt.parent != null && jointSet.Contains(jt.parent)) continue;
                        tops++;
                        top = jt;
                    }
                    int? skeletonNode = tops == 1 && top != null ? nodeIndex[top] : (int?)null;
                    var skinIdx = g.AddSkin(prefab.name + "_skin", jointNodes, ibms, skeletonNode);

                    foreach (var smr in smrs)
                    {
                        var mesh = smr.sharedMesh;
                        if (mesh == null) continue;
                        // Remap this SMR's bone indices onto the shared joint list.
                        var remap = new int[smr.bones.Length];
                        for (var b = 0; b < smr.bones.Length; b++)
                        {
                            var bt = smr.bones[b];
                            remap[b] = bt != null ? jointOrder.IndexOf(bt) : 0;
                            if (remap[b] < 0) remap[b] = 0;
                        }
                        var matIds = new List<string>();
                        foreach (var m in smr.sharedMaterials)
                        {
                            if (m == null) { matIds.Add(""); continue; }
                            ctx.EnqueueMaterial(m);
                            matIds.Add(ctx.Id(m));
                        }
                        var meshIdx = g.AddSkinnedMesh(mesh, remap, matIds, ctx);
                        g.AttachMesh(nodeIndex[smr.transform], meshIdx, skinIdx);
                        info.VertexCount += mesh.vertexCount;
                        if (info.MaterialIds.Count == 0) info.MaterialIds.AddRange(matIds);
                    }
                }

                if (clips != null)
                {
                    using (var sampler = new MecanimSampler(root))
                    {
                        foreach (var kv in clips)
                            BakeClip(g, kv.Key, kv.Value, sampler, transforms, rest, jointSet);
                    }
                    // Restore rest so later users see the authored pose.
                    RestoreRest(transforms, rest);
                }

                g.WriteGlb(outPath);
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(root);
            }
            return info;
        }

        static bool IsPureContainerOfRenderers(Transform t, HashSet<Transform> rendererNodes)
        {
            // e.g. "SM_Mesh" holds only renderer children and nothing else.
            if (t.childCount == 0) return false;
            foreach (Transform c in t)
            {
                if (rendererNodes.Contains(c)) continue;
                if (!IsPureContainerOfRenderers(c, rendererNodes)) return false;
            }
            return true;
        }

        internal static void CollectDepthFirst(Transform t, List<Transform> list)
        {
            list.Add(t);
            for (var i = 0; i < t.childCount; i++)
                CollectDepthFirst(t.GetChild(i), list);
        }

        /// <summary>
        /// Poses a rig with Mecanim's own evaluator, exactly the way the runtime does: a controller-less,
        /// avatar-less <see cref="Animator"/> on the character root driven by an
        /// <see cref="AnimationClipPlayable"/> and <see cref="PlayableGraph.Evaluate()"/>.
        /// <c>AnimationClip.SampleAnimation</c> is NOT equivalent: it evaluates the raw curves, while the
        /// PlayableGraph applies the clip's Loop Pose blend (start/end pose difference spread over the
        /// clip) and holds the last pose at the clip end instead of wrapping (docs/design.md §4).
        /// </summary>
        internal sealed class MecanimSampler : IDisposable
        {
            readonly Animator _animator;
            readonly bool _added;
            PlayableGraph _graph;
            AnimationPlayableOutput _output;
            AnimationClipPlayable _clipPlayable;
            AnimationClip _clip;

            public MecanimSampler(GameObject root)
            {
                _animator = root.GetComponent<Animator>();
                if (_animator == null)
                {
                    _animator = root.AddComponent<Animator>();
                    _added = true;
                }
                _animator.runtimeAnimatorController = null;
                _animator.avatar = null;
                _animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
                _graph = PlayableGraph.Create("AxieGltfExporter.MecanimSampler");
                _graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
                _output = AnimationPlayableOutput.Create(_graph, "Axie", _animator);
            }

            /// <summary>Write the clip pose at <paramref name="time"/> (seconds) onto the rig.</summary>
            public void Sample(AnimationClip clip, float time)
            {
                if (clip != _clip)
                {
                    if (_clipPlayable.IsValid()) _clipPlayable.Destroy();
                    _clipPlayable = AnimationClipPlayable.Create(_graph, clip);
                    _clipPlayable.SetApplyFootIK(false);
                    _clipPlayable.SetApplyPlayableIK(false);
                    _output.SetSourcePlayable(_clipPlayable);
                    _clip = clip;
                }
                _clipPlayable.SetTime(time);
                _graph.Evaluate();
            }

            public void Dispose()
            {
                if (_graph.IsValid()) _graph.Destroy();
                if (_added && _animator != null) UnityEngine.Object.DestroyImmediate(_animator);
            }
        }

        static void RestoreRest(List<Transform> transforms, RestTrs[] rest)
        {
            for (var i = 0; i < transforms.Count; i++)
            {
                transforms[i].localPosition = rest[i].P;
                transforms[i].localRotation = rest[i].R;
                transforms[i].localScale = rest[i].S;
            }
        }

        /// <summary>
        /// Edit-mode Camera.Render() feeds URP `_Time` from Time.realtimeSinceStartup, so any panner
        /// (`_Time.y * speed + uv`) in Mystic_Final lands at an unknowable phase. Zero every speed / time
        /// multiplier on the mystic materials of this character so the oracle is exactly the t = 0 frame
        /// (Godot side: `mystic_time = 0`). Returns the originals for RestoreShaderTime.
        /// </summary>
        static readonly string[] FrozenVectorProps = { "_NoiseMap_ViewDIr", "_NoiseMap_2", "_Noise3_UVSPEED", "_UV2_speed" };
        static readonly string[] FrozenFloatProps = { "_Color_Time" };

        static Dictionary<Material, (Dictionary<string, Vector4> vecs, Dictionary<string, float> floats)> FreezeShaderTime(GameObject root)
        {
            var saved = new Dictionary<Material, (Dictionary<string, Vector4>, Dictionary<string, float>)>();
            foreach (var r in root.GetComponentsInChildren<Renderer>(true))
            {
                foreach (var m in r.sharedMaterials)
                {
                    if (m == null || m.shader == null || saved.ContainsKey(m)) continue;
                    if (!m.shader.name.Contains("Mystic")) continue;
                    var vecs = new Dictionary<string, Vector4>();
                    var floats = new Dictionary<string, float>();
                    foreach (var prop in FrozenVectorProps)
                    {
                        if (!m.HasProperty(prop)) continue;
                        var v = m.GetVector(prop);
                        vecs[prop] = v;
                        // xy = tiling, zw = speed for the noise panners; _UV2_speed is a pure speed (xy).
                        m.SetVector(prop, prop == "_UV2_speed" ? Vector4.zero : new Vector4(v.x, v.y, 0f, 0f));
                    }
                    foreach (var prop in FrozenFloatProps)
                    {
                        if (!m.HasProperty(prop)) continue;
                        floats[prop] = m.GetFloat(prop);
                        m.SetFloat(prop, 0f);
                    }
                    saved[m] = (vecs, floats);
                }
            }
            return saved;
        }

        static void RestoreShaderTime(Dictionary<Material, (Dictionary<string, Vector4> vecs, Dictionary<string, float> floats)> saved)
        {
            foreach (var kv in saved)
            {
                if (kv.Key == null) continue;
                foreach (var v in kv.Value.vecs) kv.Key.SetVector(v.Key, v.Value);
                foreach (var f in kv.Value.floats) kv.Key.SetFloat(f.Key, f.Value);
            }
        }

        /// <summary>
        /// Sample the clip with Mecanim (see <see cref="MecanimSampler"/>) at every sub-frame and emit
        /// fully-specified TRS channels for every joint. Constant channels collapse to two keys. Quaternions
        /// are made sign-continuous.
        /// </summary>
        static void BakeClip(GltfBuilder g, string name, AnimationClip clip, MecanimSampler sampler, List<Transform> transforms, RestTrs[] rest, HashSet<Transform> jointSet)
        {
            // Sub-frame bake: Mecanim evaluates authored Hermite tangents between the 30 fps keys and the
            // fast clips (Walk/Run legs) bend a few degrees away from the chord mid-frame, so Godot's
            // linear track interpolation needs denser samples (AXIE_GODOT_BAKE_MULT, docs/design.md §4).
            var fps = (clip.frameRate > 1f ? clip.frameRate : 30f) * BakeMult;
            var length = Mathf.Max(clip.length, 1f / fps);
            // Every sample grid point inside the clip, then the clip end (Mecanim holds the last pose
            // there; a looping player wraps before reaching it).
            var grid = Mathf.FloorToInt(length * fps + 1e-4f);
            var lastGrid = Mathf.Min(grid / fps, length);
            // The end key is emitted whenever clip.length is not on the grid, however close (Stun is
            // 2.0000002 s): the Godot Animation length must equal clip.length for one-shots to complete
            // on the same frame as Unity.
            var frames = grid + 1 + (length > lastGrid ? 1 : 0);
            var times = new float[frames];
            for (var f = 0; f <= grid; f++) times[f] = Mathf.Min(f / fps, length);
            if (frames > grid + 1) times[frames - 1] = length;

            var n = transforms.Count;
            var pos = new Vector3[n][];
            var rot = new Quaternion[n][];
            var scl = new Vector3[n][];
            for (var i = 0; i < n; i++)
            {
                pos[i] = new Vector3[frames];
                rot[i] = new Quaternion[frames];
                scl[i] = new Vector3[frames];
            }

            for (var f = 0; f < frames; f++)
            {
                RestoreRest(transforms, rest);
                sampler.Sample(clip, times[f]);
                for (var i = 0; i < n; i++)
                {
                    var t = transforms[i];
                    pos[i][f] = MV(t.localPosition);
                    rot[i][f] = MQ(t.localRotation);
                    scl[i][f] = t.localScale;
                }
            }

            var anim = g.BeginAnimation(name);
            for (var i = 0; i < n; i++)
            {
                var t = transforms[i];
                if (!jointSet.Contains(t)) continue;
                // Sign-continuous quaternions.
                for (var f = 1; f < frames; f++)
                    if (Quaternion.Dot(rot[i][f - 1], rot[i][f]) < 0f)
                        rot[i][f] = new Quaternion(-rot[i][f].x, -rot[i][f].y, -rot[i][f].z, -rot[i][f].w);

                g.AddChannel(anim, i, "translation", times, pos[i], IsConstant(pos[i], 1e-6f));
                g.AddChannel(anim, i, "rotation", times, rot[i], IsConstant(rot[i]));
                g.AddChannel(anim, i, "scale", times, scl[i], IsConstant(scl[i], 1e-6f));
            }
        }

        static bool IsConstant(Vector3[] v, float eps)
        {
            for (var i = 1; i < v.Length; i++)
                if ((v[i] - v[0]).sqrMagnitude > eps * eps) return false;
            return true;
        }

        static bool IsConstant(Quaternion[] q)
        {
            for (var i = 1; i < q.Length; i++)
                if (Mathf.Abs(Quaternion.Dot(q[i], q[0])) < 1f - 1e-7f) return false;
            return true;
        }

        // -------------------------------------------------------------------------
        // Addon prefab (particle systems) → JSON
        // -------------------------------------------------------------------------

        static void ExportAddonPrefab(GameObject prefab, string outPath, ExportContext ctx)
        {
            using var sw = new StreamWriter(outPath, false, new UTF8Encoding(false));
            using var j = new JsonWriter(sw);
            j.BeginObject();
            j.Key("name"); j.Value(prefab.name);
            j.Key("nodes");
            j.BeginArray();
            var all = new List<Transform>();
            CollectDepthFirst(prefab.transform, all);
            foreach (var t in all)
            {
                j.BeginObject();
                j.Key("name"); j.Value(t.name);
                j.Key("parent"); j.Value(t.parent != null && t != prefab.transform ? t.parent.name : "");
                j.Key("position"); WriteVec3(j, MV(t.localPosition));
                j.Key("rotation"); WriteQuat(j, MQ(t.localRotation));
                j.Key("scale"); WriteVec3(j, t.localScale);
                var ps = t.GetComponent<ParticleSystem>();
                if (ps != null)
                {
                    j.Key("particle_system");
                    WriteParticleSystem(j, ps, ctx);
                }
                var mr = t.GetComponent<MeshRenderer>();
                var mf = t.GetComponent<MeshFilter>();
                if (mr != null && mf != null && mf.sharedMesh != null)
                {
                    j.Key("mesh_renderer");
                    j.BeginObject();
                    j.Key("mesh_name"); j.Value(mf.sharedMesh.name);
                    j.Key("materials");
                    j.BeginArray();
                    foreach (var m in mr.sharedMaterials)
                    {
                        if (m == null) { j.Value(""); continue; }
                        ctx.EnqueueMaterial(m);
                        j.Value(ctx.Id(m));
                    }
                    j.EndArray();
                    j.EndObject();
                }
                j.EndObject();
            }
            j.EndArray();
            j.EndObject();
        }

        static void WriteParticleSystem(JsonWriter j, ParticleSystem ps, ExportContext ctx)
        {
            var main = ps.main;
            j.BeginObject();
            j.Key("duration"); j.Value(main.duration);
            j.Key("looping"); j.Value(main.loop);
            j.Key("prewarm"); j.Value(main.prewarm);
            j.Key("start_delay"); WriteMinMax(j, main.startDelay);
            j.Key("start_lifetime"); WriteMinMax(j, main.startLifetime);
            j.Key("start_speed"); WriteMinMax(j, main.startSpeed);
            j.Key("start_size_3d"); j.Value(main.startSize3D);
            j.Key("start_size"); WriteMinMax(j, main.startSize);
            j.Key("start_size_x"); WriteMinMax(j, main.startSizeX);
            j.Key("start_size_y"); WriteMinMax(j, main.startSizeY);
            j.Key("start_size_z"); WriteMinMax(j, main.startSizeZ);
            j.Key("start_rotation_3d"); j.Value(main.startRotation3D);
            j.Key("start_rotation"); WriteMinMax(j, main.startRotation);
            j.Key("start_color"); WriteMinMaxGradient(j, main.startColor);
            j.Key("gravity_modifier"); WriteMinMax(j, main.gravityModifier);
            j.Key("simulation_space"); j.Value(main.simulationSpace.ToString());
            j.Key("simulation_speed"); j.Value(main.simulationSpeed);
            j.Key("scaling_mode"); j.Value(main.scalingMode.ToString());
            j.Key("max_particles"); j.Value(main.maxParticles);
            j.Key("play_on_awake"); j.Value(main.playOnAwake);

            var em = ps.emission;
            j.Key("emission");
            j.BeginObject();
            j.Key("enabled"); j.Value(em.enabled);
            j.Key("rate_over_time"); WriteMinMax(j, em.rateOverTime);
            j.Key("rate_over_distance"); WriteMinMax(j, em.rateOverDistance);
            j.Key("bursts");
            j.BeginArray();
            var bursts = new ParticleSystem.Burst[em.burstCount];
            em.GetBursts(bursts);
            foreach (var b in bursts)
            {
                j.BeginObject();
                j.Key("time"); j.Value(b.time);
                j.Key("count"); WriteMinMax(j, b.count);
                j.Key("cycle_count"); j.Value(b.cycleCount);
                j.Key("repeat_interval"); j.Value(b.repeatInterval);
                j.Key("probability"); j.Value(b.probability);
                j.EndObject();
            }
            j.EndArray();
            j.EndObject();

            var sh = ps.shape;
            j.Key("shape");
            j.BeginObject();
            j.Key("enabled"); j.Value(sh.enabled);
            j.Key("shape_type"); j.Value(sh.shapeType.ToString());
            j.Key("radius"); j.Value(sh.radius);
            j.Key("radius_thickness"); j.Value(sh.radiusThickness);
            j.Key("angle"); j.Value(sh.angle);
            j.Key("length"); j.Value(sh.length);
            j.Key("arc"); j.Value(sh.arc);
            j.Key("box_thickness"); WriteVec3(j, sh.boxThickness);
            j.Key("position"); WriteVec3(j, MV(sh.position));
            j.Key("rotation_euler"); WriteVec3(j, new Vector3(sh.rotation.x, -sh.rotation.y, -sh.rotation.z));
            j.Key("scale"); WriteVec3(j, sh.scale);
            j.Key("random_direction_amount"); j.Value(sh.randomDirectionAmount);
            j.Key("spherical_direction_amount"); j.Value(sh.sphericalDirectionAmount);
            j.Key("align_to_direction"); j.Value(sh.alignToDirection);
            j.EndObject();

            var col = ps.colorOverLifetime;
            j.Key("color_over_lifetime");
            j.BeginObject();
            j.Key("enabled"); j.Value(col.enabled);
            j.Key("color"); WriteMinMaxGradient(j, col.color);
            j.EndObject();

            var soc = ps.sizeOverLifetime;
            j.Key("size_over_lifetime");
            j.BeginObject();
            j.Key("enabled"); j.Value(soc.enabled);
            j.Key("separate_axes"); j.Value(soc.separateAxes);
            j.Key("size"); WriteMinMax(j, soc.size);
            j.Key("x"); WriteMinMax(j, soc.x);
            j.Key("y"); WriteMinMax(j, soc.y);
            j.Key("z"); WriteMinMax(j, soc.z);
            j.EndObject();

            var vol = ps.velocityOverLifetime;
            j.Key("velocity_over_lifetime");
            j.BeginObject();
            j.Key("enabled"); j.Value(vol.enabled);
            j.Key("space"); j.Value(vol.space.ToString());
            j.Key("x"); WriteMinMax(j, vol.x, -1f);
            j.Key("y"); WriteMinMax(j, vol.y);
            j.Key("z"); WriteMinMax(j, vol.z);
            j.Key("speed_modifier"); WriteMinMax(j, vol.speedModifier);
            j.Key("orbital_x"); WriteMinMax(j, vol.orbitalX);
            j.Key("orbital_y"); WriteMinMax(j, vol.orbitalY, -1f);
            j.Key("orbital_z"); WriteMinMax(j, vol.orbitalZ, -1f);
            j.Key("radial"); WriteMinMax(j, vol.radial);
            j.EndObject();

            var rol = ps.rotationOverLifetime;
            j.Key("rotation_over_lifetime");
            j.BeginObject();
            j.Key("enabled"); j.Value(rol.enabled);
            j.Key("separate_axes"); j.Value(rol.separateAxes);
            j.Key("z"); WriteMinMax(j, rol.z);
            j.EndObject();

            var noise = ps.noise;
            j.Key("noise");
            j.BeginObject();
            j.Key("enabled"); j.Value(noise.enabled);
            j.Key("strength"); WriteMinMax(j, noise.strength);
            j.Key("frequency"); j.Value(noise.frequency);
            j.Key("scroll_speed"); WriteMinMax(j, noise.scrollSpeed);
            j.Key("damping"); j.Value(noise.damping);
            j.Key("octave_count"); j.Value(noise.octaveCount);
            j.EndObject();

            // Custom Data module: feeds the Custom1/Custom2 vertex streams the VFX shaders read
            // (dissolve amount / softness, star threshold). Components are MinMaxCurves over lifetime.
            var cd = ps.customData;
            j.Key("custom_data");
            j.BeginObject();
            j.Key("enabled"); j.Value(cd.enabled);
            foreach (var stream in new[] { ParticleSystemCustomData.Custom1, ParticleSystemCustomData.Custom2 })
            {
                j.Key(stream.ToString().ToLowerInvariant());
                j.BeginObject();
                var mode = cd.GetMode(stream);
                j.Key("mode"); j.Value(mode.ToString());
                j.Key("vector_component_count"); j.Value(cd.GetVectorComponentCount(stream));
                j.Key("components");
                j.BeginArray();
                for (var c = 0; c < 4; c++) WriteMinMax(j, cd.GetVector(stream, c));
                j.EndArray();
                if (mode == ParticleSystemCustomDataMode.Color) { j.Key("color"); WriteMinMaxGradient(j, cd.GetColor(stream)); }
                j.EndObject();
            }
            j.EndObject();

            var tsa = ps.textureSheetAnimation;
            j.Key("texture_sheet_animation");
            j.BeginObject();
            j.Key("enabled"); j.Value(tsa.enabled);
            j.Key("num_tiles_x"); j.Value(tsa.numTilesX);
            j.Key("num_tiles_y"); j.Value(tsa.numTilesY);
            j.Key("cycle_count"); j.Value(tsa.cycleCount);
            j.Key("frame_over_time"); WriteMinMax(j, tsa.frameOverTime);
            j.Key("start_frame"); WriteMinMax(j, tsa.startFrame);
            // Sprites mode: the renderer draws the sprite's texture (overriding the material's _MainTex)
            // with the sprite's atlas rect as UVs. Grid mode tiles _MainTex itself.
            j.Key("mode"); j.Value(tsa.mode.ToString());
            j.Key("time_mode"); j.Value(tsa.timeMode.ToString());
            j.Key("fps"); j.Value(tsa.fps);
            j.Key("row_mode"); j.Value(tsa.rowMode.ToString());
            j.Key("row_index"); j.Value(tsa.rowIndex);
            j.Key("uv_channel_mask"); j.Value((int)tsa.uvChannelMask);
            j.Key("sprites");
            j.BeginArray();
            if (tsa.mode == ParticleSystemAnimationMode.Sprites)
            {
                for (var s = 0; s < tsa.spriteCount; s++)
                {
                    var sprite = tsa.GetSprite(s);
                    j.BeginObject();
                    if (sprite != null && sprite.texture != null)
                    {
                        ctx.EnqueueTexture(sprite.texture);
                        j.Key("name"); j.Value(sprite.name);
                        j.Key("texture"); j.Value(ctx.Id(sprite.texture));
                        var tr = sprite.textureRect;
                        var tw = (float)sprite.texture.width;
                        var th = (float)sprite.texture.height;
                        // Normalised rect in Unity UV space (V up).
                        j.Key("rect"); j.BeginArray(); j.Value(tr.x / tw); j.Value(tr.y / th); j.Value(tr.width / tw); j.Value(tr.height / th); j.EndArray();
                        j.Key("pivot"); j.BeginArray(); j.Value(sprite.pivot.x / tr.width); j.Value(sprite.pivot.y / tr.height); j.EndArray();
                        j.Key("pixels_per_unit"); j.Value(sprite.pixelsPerUnit);
                    }
                    j.EndObject();
                }
            }
            j.EndArray();
            j.EndObject();

            var r = ps.GetComponent<ParticleSystemRenderer>();
            j.Key("renderer");
            j.BeginObject();
            if (r != null)
            {
                j.Key("enabled"); j.Value(r.enabled);
                j.Key("render_mode"); j.Value(r.renderMode.ToString());
                j.Key("sort_mode"); j.Value(r.sortMode.ToString());
                j.Key("min_particle_size"); j.Value(r.minParticleSize);
                j.Key("max_particle_size"); j.Value(r.maxParticleSize);
                j.Key("alignment"); j.Value(r.alignment.ToString());
                j.Key("length_scale"); j.Value(r.lengthScale);
                j.Key("velocity_scale"); j.Value(r.velocityScale);
                j.Key("pivot"); WriteVec3(j, r.pivot);
                j.Key("material");
                if (r.sharedMaterial != null)
                {
                    ctx.EnqueueMaterial(r.sharedMaterial);
                    j.Value(ctx.Id(r.sharedMaterial));
                }
                else j.Value("");
                j.Key("mesh_name"); j.Value(r.mesh != null ? r.mesh.name : "");
                var streams = new List<ParticleSystemVertexStream>();
                r.GetActiveVertexStreams(streams);
                j.Key("vertex_streams");
                j.BeginArray();
                foreach (var s in streams) j.Value(s.ToString());
                j.EndArray();
            }
            j.EndObject();
            j.EndObject();
        }

        static void WriteMinMax(JsonWriter j, ParticleSystem.MinMaxCurve c, float sign = 1f)
        {
            j.BeginObject();
            j.Key("mode"); j.Value(c.mode.ToString());
            j.Key("constant"); j.Value(c.constant * sign);
            j.Key("constant_min"); j.Value(c.constantMin * sign);
            j.Key("constant_max"); j.Value(c.constantMax * sign);
            j.Key("multiplier"); j.Value(c.curveMultiplier);
            if (c.mode == ParticleSystemCurveMode.Curve || c.mode == ParticleSystemCurveMode.TwoCurves)
            {
                j.Key("curve"); WriteCurveSamples(j, c.curve, c.curveMultiplier * sign);
                if (c.mode == ParticleSystemCurveMode.TwoCurves) { j.Key("curve_min"); WriteCurveSamples(j, c.curveMin, c.curveMultiplier * sign); }
            }
            j.EndObject();
        }

        static void WriteCurveSamples(JsonWriter j, AnimationCurve curve, float mult)
        {
            j.BeginArray();
            if (curve != null)
            {
                const int steps = 16;
                for (var i = 0; i <= steps; i++)
                    j.Value(curve.Evaluate(i / (float)steps) * mult);
            }
            j.EndArray();
        }

        static void WriteMinMaxGradient(JsonWriter j, ParticleSystem.MinMaxGradient gr)
        {
            // Only the fields the mode uses: the unused ones hold uninitialised memory in Unity's
            // struct and made every re-export rewrite all addon JSONs.
            var mode = gr.mode;
            j.BeginObject();
            j.Key("mode"); j.Value(mode.ToString());
            if (mode == ParticleSystemGradientMode.Color || mode == ParticleSystemGradientMode.TwoColors)
            {
                j.Key("color"); WriteColor(j, gr.color);
            }
            if (mode == ParticleSystemGradientMode.TwoColors)
            {
                j.Key("color_min"); WriteColor(j, gr.colorMin);
                j.Key("color_max"); WriteColor(j, gr.colorMax);
            }
            if (mode == ParticleSystemGradientMode.Gradient || mode == ParticleSystemGradientMode.TwoGradients || mode == ParticleSystemGradientMode.RandomColor)
            {
                j.Key("gradient"); WriteGradient(j, gr.gradient);
            }
            if (mode == ParticleSystemGradientMode.TwoGradients)
            {
                j.Key("gradient_min"); WriteGradient(j, gr.gradientMin);
            }
            j.EndObject();
        }

        static void WriteGradient(JsonWriter j, Gradient gr)
        {
            j.BeginObject();
            if (gr == null) { j.EndObject(); return; }
            j.Key("mode"); j.Value(gr.mode.ToString());
            j.Key("color_keys");
            j.BeginArray();
            foreach (var k in gr.colorKeys)
            {
                j.BeginObject();
                j.Key("t"); j.Value(k.time);
                j.Key("color"); WriteColor(j, k.color);
                j.EndObject();
            }
            j.EndArray();
            j.Key("alpha_keys");
            j.BeginArray();
            foreach (var k in gr.alphaKeys)
            {
                j.BeginObject();
                j.Key("t"); j.Value(k.time);
                j.Key("a"); j.Value(k.alpha);
                j.EndObject();
            }
            j.EndArray();
            j.EndObject();
        }

        // -------------------------------------------------------------------------
        // Oracle: assembled characters sampled numerically
        // -------------------------------------------------------------------------

        class OracleFixture
        {
            public string Name;
            public AxieDescriptor Descriptor;
            public string Genes;
        }

        static void RunOracle(string outDir, AxieFactory factory)
        {
            Debug.Log($"[AxieGltfExporter] oracle → {outDir}");
            if (Directory.Exists(outDir)) Directory.Delete(outDir, true);
            Directory.CreateDirectory(outDir);

            var previous = AxieFactory.Default;
            AxieFactory.Default = factory;
            var weaponCatalog = FindWeaponCatalog();
            if (weaponCatalog != null) AxieWeaponAnims.Register(weaponCatalog, factory);
            try
            {
                var fixtures = BuildFixtures();
                var samples = new List<(string clip, float t)>
                {
                    ("", 0f),
                    ("Idle", 0.2f), ("Idle", 0.5f), ("Idle", 1.0f),
                    ("Walk", 0.3f), ("Run", 0.1f), ("Stun", 0.4f), ("Dead", 0.5f),
                    ("AttackCombo", 0.3f), ("SwordAttack", 0.4f),
                };
                using var idx = new JsonWriter(new StreamWriter(Path.Combine(outDir, "index.json"), false, new UTF8Encoding(false)));
                idx.BeginObject();
                idx.Key("format_version"); idx.Value(1);
                idx.Key("space"); idx.Value("godot_right_handed_mirrored_x_world");
                idx.Key("fixtures");
                idx.BeginArray();
                foreach (var fx in fixtures)
                {
                    foreach (var combine in new[] { false, true })
                    {
                        var p = new AxieInstantiationParams { combineMeshes = combine };
                        var character = factory.CreateCharacter(fx.Descriptor, p);
                        if (character == null)
                        {
                            Debug.LogWarning($"[AxieGltfExporter] oracle: could not build {fx.Name}");
                            continue;
                        }
                        try
                        {
                            var root = character.Root;
                            var dir = Path.Combine(outDir, fx.Name + (combine ? "_combined" : ""));
                            Directory.CreateDirectory(dir);
                            var transforms = new List<Transform>();
                            CollectDepthFirst(root.transform, transforms);
                            var rest = new RestTrs[transforms.Count];
                            for (var i = 0; i < transforms.Count; i++)
                                rest[i] = new RestTrs { P = transforms[i].localPosition, R = transforms[i].localRotation, S = transforms[i].localScale };

                            var written = new List<string>();
                            using var sampler = new MecanimSampler(root);
                            foreach (var (clipName, t) in samples)
                            {
                                AnimationClip clip = null;
                                if (!string.IsNullOrEmpty(clipName))
                                {
                                    clip = character.GetAnimClip(clipName);
                                    if (clip == null) continue;
                                }
                                RestoreRest(transforms, rest);
                                if (clip != null) sampler.Sample(clip, t);
                                var file = string.IsNullOrEmpty(clipName) ? "rest.json" : $"{clipName}_{t.ToString("0.00", CultureInfo.InvariantCulture)}.json";
                                WriteOracleSample(Path.Combine(dir, file), root, transforms, clipName, t, true);
                                written.Add(file);
                            }
                            RestoreRest(transforms, rest);

                            idx.BeginObject();
                            idx.Key("name"); idx.Value(fx.Name);
                            idx.Key("combined"); idx.Value(combine);
                            idx.Key("dir"); idx.Value(Path.GetFileName(dir));
                            idx.Key("genes"); idx.Value(fx.Genes ?? "");
                            idx.Key("body"); idx.Value(fx.Descriptor.body.ToString());
                            idx.Key("color_variant"); idx.Value(fx.Descriptor.colorVariant);
                            idx.Key("parts");
                            idx.BeginArray();
                            foreach (var part in fx.Descriptor.parts)
                            {
                                idx.BeginObject();
                                idx.Key("type"); idx.Value(part.type.ToString());
                                idx.Key("class"); idx.Value(part.@class);
                                idx.Key("variant"); idx.Value(part.variant);
                                idx.Key("skin"); idx.Value(part.skin);
                                idx.Key("level"); idx.Value(part.level);
                                idx.EndObject();
                            }
                            idx.EndArray();
                            idx.Key("samples");
                            idx.BeginArray();
                            foreach (var w in written) idx.Value(w);
                            idx.EndArray();
                            idx.EndObject();
                            Debug.Log($"[AxieGltfExporter] oracle {fx.Name} combine={combine} samples={written.Count}");
                        }
                        finally
                        {
                            // Edit mode: Object.Destroy (used by Dispose) is not allowed; tear down directly.
                            var rootGo = character.Root;
                            if (rootGo != null) UnityEngine.Object.DestroyImmediate(rootGo);
                        }
                    }
                }
                idx.EndArray();
                idx.EndObject();
            }
            finally
            {
                if (weaponCatalog != null) AxieWeaponAnims.Unregister(weaponCatalog, factory);
                AxieFactory.Default = previous;
            }
        }

        // -------------------------------------------------------------------------
        // Render oracle: reference PNGs of the fixtures under a fixed camera / main light rig.
        // -------------------------------------------------------------------------

        public const int RenderSize = 512;
        static readonly Vector3 RenderCameraPos = new(0f, 1.05f, 4.6f);
        static readonly Vector3 RenderCameraTarget = new(0f, 0.8f, 0f);
        static readonly Vector3 RenderLightEuler = new(35f, 140f, 0f);
        static readonly Color RenderBackground = new(0.18f, 0.20f, 0.24f, 1f);
        static readonly Color RenderAmbient = new(0.5f, 0.5f, 0.5f, 1f);

        static void RunRenders(string outDir, AxieFactory factory)
        {
            var rootScale = float.Parse(Env("AXIE_GODOT_RENDER_SCALE", "1"), CultureInfo.InvariantCulture);
            var renderHdr = Env("AXIE_GODOT_RENDER_HDR", "0") == "1";
            var shaderTime = float.Parse(Env("AXIE_GODOT_RENDER_SHADER_TIME", "0"), CultureInfo.InvariantCulture);
            var exposure = float.Parse(Env("AXIE_GODOT_RENDER_EXPOSURE", "1"), CultureInfo.InvariantCulture);
            Debug.Log($"[AxieGltfExporter] render oracle → {outDir}");
            if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Null)
                throw new InvalidOperationException("render stage needs a graphics device (run batchmode without -nographics)");
            if (Directory.Exists(outDir)) Directory.Delete(outDir, true);
            Directory.CreateDirectory(outDir);

            var previous = AxieFactory.Default;
            AxieFactory.Default = factory;
            var weaponCatalog = FindWeaponCatalog();
            if (weaponCatalog != null) AxieWeaponAnims.Register(weaponCatalog, factory);

            var prevAmbientMode = RenderSettings.ambientMode;
            var prevAmbient = RenderSettings.ambientLight;
            var prevSkybox = RenderSettings.skybox;
            var prevFog = RenderSettings.fog;
            var prevSun = RenderSettings.sun;
            RenderSettings.ambientMode = AmbientMode.Flat;
            RenderSettings.ambientLight = RenderAmbient;
            RenderSettings.skybox = null;
            RenderSettings.fog = false;

            var camGo = new GameObject("AxieRenderOracleCamera");
            var lightGo = new GameObject("AxieRenderOracleLight");
            RenderTexture rt = null;
            Texture2D readback = null;
            // Pin the URP asset to an LDR, MSAA-free configuration so the reference is the plain shader output
            // (no HDR intermediate / resolve). Reflection: the Dev.Editor asmdef has no URP reference.
            var urpAsset = GraphicsSettings.currentRenderPipeline;
            var hdrProp = urpAsset != null ? urpAsset.GetType().GetProperty("supportsHDR") : null;
            var msaaProp = urpAsset != null ? urpAsset.GetType().GetProperty("msaaSampleCount") : null;
            var prevHdr = hdrProp?.GetValue(urpAsset);
            var prevMsaa = msaaProp?.GetValue(urpAsset);
            try
            {
                hdrProp?.SetValue(urpAsset, false);
                msaaProp?.SetValue(urpAsset, 1);
                if (renderHdr) hdrProp?.SetValue(urpAsset, true);
                var cam = camGo.AddComponent<Camera>();
                cam.clearFlags = CameraClearFlags.SolidColor;
                cam.backgroundColor = RenderBackground;
                cam.fieldOfView = 30f;
                cam.nearClipPlane = 0.05f;
                cam.farClipPlane = 50f;
                cam.allowMSAA = false;
                cam.allowHDR = renderHdr;
                cam.transform.position = RenderCameraPos * rootScale;
                cam.transform.LookAt(RenderCameraTarget * rootScale, Vector3.up);
                // URP adds UniversalAdditionalCameraData lazily with defaults (no post-processing, no AA);
                // the Dev.Editor asmdef has no URP reference so we do not touch it here.

                var light = lightGo.AddComponent<Light>();
                light.type = LightType.Directional;
                light.color = Color.white;
                light.intensity = 1f;
                light.shadows = LightShadows.None;
                lightGo.transform.rotation = Quaternion.Euler(RenderLightEuler);
                RenderSettings.sun = light;

                rt = new RenderTexture(RenderSize, RenderSize, 24, renderHdr ? RenderTextureFormat.ARGBFloat : RenderTextureFormat.ARGB32) { antiAliasing = 1 };
                rt.Create();
                cam.targetTexture = rt;
                readback = new Texture2D(RenderSize, RenderSize, renderHdr ? TextureFormat.RGBAFloat : TextureFormat.RGBA32, false, renderHdr);

                var yaws = new[] { 0f, 45f, 90f, 135f, 180f, 225f, 270f, 315f };
                var poses = new List<(string clip, float t, float[] yaws)>
                {
                    ("", 0f, yaws),
                    ("Idle", 0.5f, new[] { 0f, 180f }),
                    ("Walk", 0.3f, new[] { 45f }),
                    ("AttackCombo", 0.3f, new[] { 0f }),
                };

                using var idx = new JsonWriter(new StreamWriter(Path.Combine(outDir, "index.json"), false, new UTF8Encoding(false)));
                idx.BeginObject();
                idx.Key("format_version"); idx.Value(1);
                idx.Key("size"); idx.Value(RenderSize);
                idx.Key("color_space"); idx.Value(QualitySettings.activeColorSpace.ToString());
                idx.Key("hdr"); idx.Value(hdrProp != null && (bool)hdrProp.GetValue(urpAsset));
                idx.Key("urp_asset"); idx.Value(urpAsset != null ? urpAsset.name : "");
                idx.Key("shader_time_frozen"); idx.Value(true);
                idx.Key("root_scale"); idx.Value(rootScale);
                idx.Key("shader_time"); idx.Value(shaderTime);
                idx.Key("exposure"); idx.Value(exposure);
                idx.Key("camera");
                idx.BeginObject();
                idx.Key("position"); WriteVec3(idx, MV(RenderCameraPos * rootScale));
                idx.Key("target"); WriteVec3(idx, MV(RenderCameraTarget * rootScale));
                idx.Key("fov_vertical"); idx.Value(cam.fieldOfView);
                idx.Key("near"); idx.Value(cam.nearClipPlane);
                idx.Key("far"); idx.Value(cam.farClipPlane);
                idx.EndObject();
                idx.Key("light_forward"); WriteVec3(idx, MV(lightGo.transform.forward));
                idx.Key("light_to"); WriteVec3(idx, MV(-lightGo.transform.forward));
                idx.Key("background"); WriteColor(idx, RenderBackground);
                idx.Key("ambient"); WriteColor(idx, RenderAmbient);
                idx.Key("fixtures");
                idx.BeginArray();
                foreach (var fx in BuildFixtures())
                {
                    foreach (var combine in new[] { false, true })
                    {
                        var p = new AxieInstantiationParams { combineMeshes = combine };
                        var character = factory.CreateCharacter(fx.Descriptor, p);
                        if (character == null) continue;
                        Dictionary<Material, (Dictionary<string, Vector4> vecs, Dictionary<string, float> floats)> frozen = null;
                        var timedShaders = new Dictionary<Shader, Shader>();
                        try
                        {
                            var root = character.Root;
                            var dir = Path.Combine(outDir, fx.Name + (combine ? "_combined" : ""));
                            Directory.CreateDirectory(dir);
                            // Particle systems are not deterministic across engines; keep them out of the pixel oracle.
                            // AXIE_GODOT_RENDER_PARTICLES=1 (preview only, never for the committed oracle): keep them
                            // and simulate every system to a fixed time with a fixed seed so the mystic VFX is visible.
                            var renderParticles = Env("AXIE_GODOT_RENDER_PARTICLES", "0") == "1";
                            var particleOnly = Env("AXIE_GODOT_RENDER_PARTICLES_ONLY", "");   // material-name substring filter
                            foreach (var psr in root.GetComponentsInChildren<ParticleSystemRenderer>(true))
                                psr.enabled = renderParticles && (particleOnly.Length == 0 || (psr.sharedMaterial != null && psr.sharedMaterial.name.Contains(particleOnly)));
                            if (renderParticles)
                            {
                                var simTime = float.Parse(Env("AXIE_GODOT_RENDER_PARTICLES_TIME", "0.75"), CultureInfo.InvariantCulture);
                                var particleDebug = Env("AXIE_GODOT_RENDER_PARTICLES_DEBUG", "");   // "notsa": disable texture-sheet animation
                                foreach (var ps in root.GetComponentsInChildren<ParticleSystem>(true))
                                {
                                    if (particleDebug.Contains("notsa")) { var tsaMod = ps.textureSheetAnimation; tsaMod.enabled = false; }
                                    var tsaFrame = Env("AXIE_GODOT_RENDER_PARTICLES_TSAFRAME", "");   // force frameOverTime constant
                                    if (tsaFrame.Length > 0) { var tsaMod = ps.textureSheetAnimation; tsaMod.frameOverTime = new ParticleSystem.MinMaxCurve(float.Parse(tsaFrame, CultureInfo.InvariantCulture)); }
                                    var custom1 = Env("AXIE_GODOT_RENDER_PARTICLES_CUSTOM1", "");   // "x,y,z,w": force Custom1 constants
                                    if (custom1.Length > 0)
                                    {
                                        var parts = custom1.Split(',');
                                        var cdMod = ps.customData;
                                        cdMod.enabled = true;
                                        cdMod.SetMode(ParticleSystemCustomData.Custom1, ParticleSystemCustomDataMode.Vector);
                                        cdMod.SetVectorComponentCount(ParticleSystemCustomData.Custom1, 4);
                                        for (var c = 0; c < 4 && c < parts.Length; c++)
                                            cdMod.SetVector(ParticleSystemCustomData.Custom1, c, new ParticleSystem.MinMaxCurve(float.Parse(parts[c], CultureInfo.InvariantCulture)));
                                    }
                                    ps.Stop(false, ParticleSystemStopBehavior.StopEmittingAndClear);
                                    ps.useAutoRandomSeed = false;
                                    ps.randomSeed = 1234;
                                    ps.Simulate(simTime, false, true, true);
                                }
                            }
                            // Time-scrolled mystic panners: pin to the t = 0 frame (see FreezeShaderTime).
                            if (shaderTime == 0f) frozen = FreezeShaderTime(root);
                            else PinShaderTime(root, shaderTime, timedShaders);
                            // Skin matrices are normally refreshed by the player loop, not by Camera.Render(); without
                            // this the edit-mode render shows the previous sample's pose.
                            foreach (var smr in root.GetComponentsInChildren<SkinnedMeshRenderer>(true)) smr.forceMatrixRecalculationPerRender = true;
                            var transforms = new List<Transform>();
                            CollectDepthFirst(root.transform, transforms);
                            var rest = new RestTrs[transforms.Count];
                            for (var i = 0; i < transforms.Count; i++)
                                rest[i] = new RestTrs { P = transforms[i].localPosition, R = transforms[i].localRotation, S = transforms[i].localScale };

                            var written = new List<(string file, string clip, float t, float yaw)>();
                            using var sampler = new MecanimSampler(root);
                            foreach (var (clipName, t, poseYaws) in poses)
                            {
                                AnimationClip clip = null;
                                if (!string.IsNullOrEmpty(clipName))
                                {
                                    clip = character.GetAnimClip(clipName);
                                    if (clip == null) continue;
                                }
                                foreach (var yaw in poseYaws)
                                {
                                    RestoreRest(transforms, rest);
                                    if (clip != null) sampler.Sample(clip, t);
                                    root.transform.rotation = Quaternion.Euler(0f, yaw, 0f);
                                    root.transform.localScale = Vector3.one * rootScale;
                                    cam.Render();
                                    var prevActive = RenderTexture.active;
                                    RenderTexture.active = rt;
                                    readback.ReadPixels(new Rect(0, 0, RenderSize, RenderSize), 0, 0);
                                    readback.Apply();
                                    RenderTexture.active = prevActive;
                                    var tag = string.IsNullOrEmpty(clipName) ? "rest" : $"{clipName}_{t.ToString("0.00", CultureInfo.InvariantCulture)}";
                                    var file = $"{tag}_y{yaw:000}.png";
                                    if (renderHdr)
                                    {
                                        File.WriteAllBytes(Path.Combine(dir, Path.ChangeExtension(file, ".exr")), readback.EncodeToEXR(Texture2D.EXRFlags.OutputAsFloat));
                                        var colors = readback.GetPixels();
                                        var peak = 0f;
                                        var hdrPixels = 0;
                                        for (var c = 0; c < colors.Length; c++)
                                        {
                                            peak = Mathf.Max(peak, colors[c].maxColorComponent);
                                            if (colors[c].maxColorComponent > 1.01f) hdrPixels++;
                                            colors[c] = HdrDisplayColor(colors[c], exposure);
                                        }
                                        var png = new Texture2D(RenderSize, RenderSize, TextureFormat.RGBA32, false);
                                        png.SetPixels(colors); png.Apply();
                                        File.WriteAllBytes(Path.Combine(dir, file), png.EncodeToPNG());
                                        UnityEngine.Object.DestroyImmediate(png);
                                        Debug.Log($"[AxieGltfExporter] HDR {fx.Name} combined={combine} {file} peak={peak} pixels={hdrPixels}");
                                    }
                                    else File.WriteAllBytes(Path.Combine(dir, file), readback.EncodeToPNG());
                                    written.Add((file, clipName, t, yaw));
                                }
                            }
                            RestoreRest(transforms, rest);
                            root.transform.rotation = Quaternion.identity;

                            idx.BeginObject();
                            idx.Key("name"); idx.Value(fx.Name);
                            idx.Key("combined"); idx.Value(combine);
                            idx.Key("dir"); idx.Value(Path.GetFileName(dir));
                            idx.Key("genes"); idx.Value(fx.Genes ?? "");
                            idx.Key("body"); idx.Value(fx.Descriptor.body.ToString());
                            idx.Key("color_variant"); idx.Value(fx.Descriptor.colorVariant);
                            idx.Key("parts");
                            idx.BeginArray();
                            foreach (var part in fx.Descriptor.parts)
                            {
                                idx.BeginObject();
                                idx.Key("type"); idx.Value(part.type.ToString());
                                idx.Key("class"); idx.Value(part.@class);
                                idx.Key("variant"); idx.Value(part.variant);
                                idx.Key("skin"); idx.Value(part.skin);
                                idx.Key("level"); idx.Value(part.level);
                                idx.EndObject();
                            }
                            idx.EndArray();
                            idx.Key("images");
                            idx.BeginArray();
                            foreach (var w in written)
                            {
                                idx.BeginObject();
                                idx.Key("file"); idx.Value(w.file);
                                idx.Key("clip"); idx.Value(w.clip);
                                idx.Key("time"); idx.Value(w.t);
                                idx.Key("yaw_unity_deg"); idx.Value(w.yaw);
                                idx.EndObject();
                            }
                            idx.EndArray();
                            idx.EndObject();
                            Debug.Log($"[AxieGltfExporter] render {fx.Name} combine={combine} images={written.Count}");
                        }
                        finally
                        {
                            if (frozen != null) RestoreShaderTime(frozen);
                            var rootGo = character.Root;
                            if (rootGo != null) UnityEngine.Object.DestroyImmediate(rootGo);
                            foreach (var shader in timedShaders.Values) UnityEngine.Object.DestroyImmediate(shader);
                        }
                    }
                }
                idx.EndArray();
                idx.EndObject();
            }
            finally
            {
                if (rt != null) { rt.Release(); UnityEngine.Object.DestroyImmediate(rt); }
                if (readback != null) UnityEngine.Object.DestroyImmediate(readback);
                UnityEngine.Object.DestroyImmediate(camGo);
                UnityEngine.Object.DestroyImmediate(lightGo);
                if (prevHdr != null) hdrProp.SetValue(urpAsset, prevHdr);
                if (prevMsaa != null) msaaProp.SetValue(urpAsset, prevMsaa);
                RenderSettings.ambientMode = prevAmbientMode;
                RenderSettings.ambientLight = prevAmbient;
                RenderSettings.skybox = prevSkybox;
                RenderSettings.fog = prevFog;
                RenderSettings.sun = prevSun;
                if (weaponCatalog != null) AxieWeaponAnims.Unregister(weaponCatalog, factory);
                AxieFactory.Default = previous;
            }
        }

        // Compile transient copies of the original shaders with only their time inputs pinned.
        // Source assets and material values are unchanged; this also covers nonzero panner phases.
        static void PinShaderTime(GameObject root, float time, Dictionary<Shader, Shader> copies)
        {
            var literal = time.ToString("0.########", CultureInfo.InvariantCulture);
            foreach (var renderer in root.GetComponentsInChildren<Renderer>(true))
                foreach (var material in renderer.sharedMaterials)
                {
                    if (material == null || material.shader == null || !material.shader.name.Contains("Mystic")) continue;
                    var original = material.shader;
                    if (copies.ContainsValue(original)) continue;
                    if (!copies.TryGetValue(original, out var timed))
                    {
                        var path = AssetDatabase.GetAssetPath(original);
                        if (!path.EndsWith(".shader", StringComparison.Ordinal))
                            throw new InvalidOperationException($"Cannot pin shader time for {path}");
                        var source = File.ReadAllText(path).Replace("_TimeParameters.x", literal).Replace("_Time.y", literal);
                        timed = ShaderUtil.CreateShaderAsset(source, true);
                        if (ShaderUtil.ShaderHasError(timed)) throw new InvalidOperationException($"Timed shader failed: {path}");
                        copies.Add(original, timed);
                    }
                    material.shader = timed;
                }
        }

        // The Unity project shades in gamma space. Convert the floating-point render into the
        // same linear exposure + display transfer used by Godot, without bloom or tonemap curves.
        static Color HdrDisplayColor(Color value, float exposure)
        {
            float Channel(float c)
            {
                c = Mathf.Max(c, 0f);
                var linear = c <= 0.04045f ? c / 12.92f : Mathf.Pow((c + 0.055f) / 1.055f, 2.4f);
                linear = Mathf.Min(linear, 65504f) * exposure;
                return Mathf.Clamp01(linear <= 0.0031308f ? linear * 12.92f : 1.055f * Mathf.Pow(linear, 1f / 2.4f) - 0.055f);
            }
            return new Color(Channel(value.r), Channel(value.g), Channel(value.b), 1f);
        }

        static List<OracleFixture> BuildFixtures()
        {
            var list = new List<OracleFixture>();
            // Beast V02 S00 L1 on Normal, color 3 (the historical golden fixture).
            list.Add(new OracleFixture
            {
                Name = "beast02_s00_normal",
                Descriptor = MakeDescriptor(AxieBodyType.Normal, 3, "Beast", 2, 0, 1),
            });
            // Mystic Beast V02 S01 L1.
            list.Add(new OracleFixture
            {
                Name = "beast02_s01_normal",
                Descriptor = MakeDescriptor(AxieBodyType.Normal, 3, "Beast", 2, 1, 1),
            });
            // Every body type with Aquatic 04 to exercise attach points across rigs.
            foreach (AxieBodyType body in Enum.GetValues(typeof(AxieBodyType)))
            {
                if (body == AxieBodyType.Normal) continue;
                list.Add(new OracleFixture
                {
                    Name = $"aquatic04_s00_{body.ToString().ToLowerInvariant()}",
                    Descriptor = MakeDescriptor(body, body == AxieBodyType.Frosty ? 48 : 12, "Aquatic", 4, 0, 1),
                });
            }
            // Live IDs from the pinned sample pack (genes decoded by the Unity codec = the oracle).
            var samplePath = Env("AXIE_GODOT_SAMPLE_JSON", DefaultSampleJson);
            if (File.Exists(samplePath))
            {
                try
                {
                    var text = File.ReadAllText(samplePath);
                    foreach (Match m in Regex.Matches(text, "\"id\":\\s*\"(?<id>\\d+)\"[\\s\\S]*?\"genes\":\\s*\"(?<genes>0x[0-9a-fA-F]+)\""))
                    {
                        var genes = m.Groups["genes"].Value;
                        if (genes.Length < 130) continue;
                        try
                        {
                            list.Add(new OracleFixture
                            {
                                Name = "axie_" + m.Groups["id"].Value,
                                Descriptor = AxieDescriptor.FromGenes(genes),
                                Genes = genes,
                            });
                        }
                        catch (Exception ex)
                        {
                            Debug.LogWarning($"[AxieGltfExporter] oracle: genes for #{m.Groups["id"].Value} failed: {ex.Message}");
                        }
                    }
                }
                catch (Exception ex)
                {
                    Debug.LogWarning($"[AxieGltfExporter] oracle: sample json unreadable: {ex.Message}");
                }
            }
            var filter = Env("AXIE_GODOT_FIXTURES", "");
            if (!string.IsNullOrEmpty(filter))
            {
                var names = new HashSet<string>(filter.Split(','));
                list.RemoveAll(fx => !names.Contains(fx.Name));
            }
            return list;
        }

        internal static AxieDescriptor MakeDescriptor(AxieBodyType body, int color, string cls, int variant, int skin, int level)
        {
            var d = new AxieDescriptor { body = body, colorVariant = color, parts = new List<AxiePartDescriptor>() };
            foreach (AxiePartType pt in Enum.GetValues(typeof(AxiePartType)))
                d.parts.Add(new AxiePartDescriptor { type = pt, @class = cls, variant = variant, skin = skin, level = level });
            return d;
        }

        static void WriteOracleSample(string path, GameObject root, List<Transform> transforms, string clip, float t, bool withVertices)
        {
            using var sw = new StreamWriter(path, false, new UTF8Encoding(false));
            using var j = new JsonWriter(sw);
            j.BeginObject();
            j.Key("clip"); j.Value(clip ?? "");
            j.Key("time"); j.Value(t);
            j.Key("root"); j.Value(root.name);
            j.Key("nodes");
            j.BeginArray();
            var rootInv = root.transform.worldToLocalMatrix;
            foreach (var tr in transforms)
            {
                // World TRS relative to the character root, mirrored into Godot space.
                var m = MM(rootInv * tr.localToWorldMatrix);
                j.BeginObject();
                j.Key("path"); j.Value(PathFrom(root.transform, tr));
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
            if (withVertices)
            {
                j.Key("renderers");
                j.BeginArray();
                var baked = new Mesh();
                foreach (var smr in root.GetComponentsInChildren<SkinnedMeshRenderer>(true))
                {
                    if (smr.sharedMesh == null) continue;
                    baked.Clear();
                    smr.BakeMesh(baked, true);
                    var verts = baked.vertices;
                    var l2w = rootInv * smr.transform.localToWorldMatrix;
                    j.BeginObject();
                    j.Key("path"); j.Value(PathFrom(root.transform, smr.transform));
                    j.Key("mesh"); j.Value(smr.sharedMesh.name);
                    j.Key("vertex_count"); j.Value(verts.Length);
                    j.Key("bounds_center"); WriteVec3(j, MV(l2w.MultiplyPoint3x4(baked.bounds.center)));
                    j.Key("bounds_size"); WriteVec3(j, baked.bounds.size);
                    j.Key("vertices");
                    j.BeginArray();
                    foreach (var v in verts)
                    {
                        var w = MV(l2w.MultiplyPoint3x4(v));
                        j.Value(w.x); j.Value(w.y); j.Value(w.z);
                    }
                    j.EndArray();
                    j.EndObject();
                }
                UnityEngine.Object.DestroyImmediate(baked);
                j.EndArray();
            }
            j.EndObject();
        }

        internal static string PathFrom(Transform root, Transform t)
        {
            if (t == root) return "";
            var parts = new List<string>();
            var cur = t;
            while (cur != null && cur != root)
            {
                parts.Add(cur.name);
                cur = cur.parent;
            }
            parts.Reverse();
            return string.Join("/", parts);
        }

        // -------------------------------------------------------------------------
        // Materials / textures (same JSON schema as the v1 exporter)
        // -------------------------------------------------------------------------

        static void WriteMaterial(string exportDir, ExportContext ctx, Material material)
        {
            var path = Path.Combine(exportDir, "materials", ctx.Id(material) + ".json");
            using var sw = new StreamWriter(path, false, new UTF8Encoding(false));
            using var j = new JsonWriter(sw);
            j.BeginObject();
            j.Key("id"); j.Value(ctx.Id(material));
            j.Key("name"); j.Value(material.name);
            j.Key("shader"); j.Value(material.shader != null ? material.shader.name : "");
            j.Key("render_queue"); j.Value(material.renderQueue);
            j.Key("keywords");
            j.BeginArray();
            foreach (var k in material.shaderKeywords) j.Value(k);
            j.EndArray();

            var colors = new List<KeyValuePair<string, Color>>();
            var floats = new List<KeyValuePair<string, float>>();
            var ints = new List<KeyValuePair<string, int>>();
            var vectors = new List<KeyValuePair<string, Vector4>>();
            var textures = new List<(string name, string id, Vector2 scale, Vector2 offset)>();

            var shader = material.shader;
            if (shader != null)
            {
                var count = shader.GetPropertyCount();
                for (var i = 0; i < count; i++)
                {
                    var pname = shader.GetPropertyName(i);
                    if (string.IsNullOrEmpty(pname) || pname.StartsWith("unity_", StringComparison.Ordinal)) continue;
                    if (!material.HasProperty(pname)) continue;
                    switch (shader.GetPropertyType(i))
                    {
                        case ShaderPropertyType.Color: colors.Add(new(pname, material.GetColor(pname))); break;
                        case ShaderPropertyType.Float:
                        case ShaderPropertyType.Range: floats.Add(new(pname, material.GetFloat(pname))); break;
                        case ShaderPropertyType.Int: ints.Add(new(pname, material.GetInt(pname))); break;
                        case ShaderPropertyType.Vector: vectors.Add(new(pname, material.GetVector(pname))); break;
                        case ShaderPropertyType.Texture:
                            if (SkippedTextureProps.Contains(pname)) break;
                            var tex = material.GetTexture(pname);
                            string texId = null;
                            if (tex != null) { ctx.EnqueueTexture(tex); texId = ctx.Id(tex); }
                            textures.Add((pname, texId, material.GetTextureScale(pname), material.GetTextureOffset(pname)));
                            break;
                    }
                }
            }

            j.Key("colors"); j.BeginObject();
            foreach (var kv in colors) { j.Key(kv.Key); WriteColor(j, kv.Value); }
            j.EndObject();
            j.Key("floats"); j.BeginObject();
            foreach (var kv in floats) { j.Key(kv.Key); j.Value(kv.Value); }
            j.EndObject();
            j.Key("ints"); j.BeginObject();
            foreach (var kv in ints) { j.Key(kv.Key); j.Value(kv.Value); }
            j.EndObject();
            j.Key("vectors"); j.BeginObject();
            foreach (var kv in vectors) { j.Key(kv.Key); WriteVec4(j, kv.Value); }
            j.EndObject();
            j.Key("textures"); j.BeginObject();
            foreach (var t in textures)
            {
                j.Key(t.name);
                j.BeginObject();
                j.Key("texture"); if (t.id == null) j.ValueNull(); else j.Value(t.id);
                j.Key("scale"); WriteVec2(j, t.scale);
                j.Key("offset"); WriteVec2(j, t.offset);
                j.EndObject();
            }
            j.EndObject();
            j.EndObject();
        }

        /// <summary>
        /// Writes the texture exactly as Unity samples it: the *imported* texel data (max size, format
        /// decoded on the GPU), plus the importer's sampling settings so the Godot loader can mirror them
        /// (mipmaps on/off, filter, wrap). Falls back to copying the source file when there is no GPU.
        /// </summary>
        static void WriteTexture(string exportDir, string id, Texture texture, JsonWriter manifest)
        {
            var assetPath = AssetDatabase.GetAssetPath(texture);
            var importer = string.IsNullOrEmpty(assetPath) ? null : AssetImporter.GetAtPath(assetPath) as TextureImporter;
            var file = id + ".png";
            var dest = Path.Combine(exportDir, "textures", file);
            var written = false;
            var t2d = texture as Texture2D;

            if (t2d != null && SystemInfo.graphicsDeviceType != GraphicsDeviceType.Null)
            {
                RenderTexture rt = null;
                Texture2D readback = null;
                var prevActive = RenderTexture.active;
                try
                {
                    // Gamma-space project: Blit copies texel values 1:1 (no sRGB conversions).
                    rt = RenderTexture.GetTemporary(t2d.width, t2d.height, 0, RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear);
                    Graphics.Blit(t2d, rt);
                    readback = new Texture2D(t2d.width, t2d.height, TextureFormat.RGBA32, false, true);
                    RenderTexture.active = rt;
                    readback.ReadPixels(new Rect(0, 0, t2d.width, t2d.height), 0, 0);
                    readback.Apply();
                    var png = readback.EncodeToPNG();
                    if (png != null && png.Length > 0) { File.WriteAllBytes(dest, png); written = true; }
                }
                catch (Exception ex) { Debug.LogWarning($"[AxieGltfExporter] blit export failed for '{texture.name}': {ex.Message}"); }
                finally
                {
                    RenderTexture.active = prevActive;
                    if (rt != null) RenderTexture.ReleaseTemporary(rt);
                    if (readback != null) UnityEngine.Object.DestroyImmediate(readback);
                }
            }
            if (!written)
            {
                var ext = string.IsNullOrEmpty(assetPath) ? "" : Path.GetExtension(assetPath).ToLowerInvariant();
                if (ext == ".png" || ext == ".jpg" || ext == ".jpeg")
                {
                    var abs = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(Application.dataPath) ?? "", assetPath));
                    if (File.Exists(abs))
                    {
                        file = id + ext;
                        File.Copy(abs, Path.Combine(exportDir, "textures", file), true);
                        written = true;
                        Debug.LogWarning($"[AxieGltfExporter] texture '{texture.name}' copied from source (no graphics device); size may differ from Unity's import.");
                    }
                }
            }
            if (!written)
            {
                Debug.LogWarning($"[AxieGltfExporter] Could not export texture '{texture.name}' ({assetPath}).");
                return;
            }

            manifest.Key(id);
            manifest.BeginObject();
            manifest.Key("file"); manifest.Value("textures/" + file);
            manifest.Key("name"); manifest.Value(texture.name ?? "");
            manifest.Key("width"); manifest.Value(texture.width);
            manifest.Key("height"); manifest.Value(texture.height);
            manifest.Key("mipmaps"); manifest.Value(texture.mipmapCount > 1);
            manifest.Key("filter"); manifest.Value(texture.filterMode.ToString());
            manifest.Key("aniso"); manifest.Value(texture.anisoLevel);
            manifest.Key("wrap_u"); manifest.Value(texture.wrapModeU.ToString());
            manifest.Key("wrap_v"); manifest.Value(texture.wrapModeV.ToString());
            manifest.Key("srgb"); manifest.Value(importer == null || importer.sRGBTexture);
            manifest.Key("alpha_is_transparency"); manifest.Value(importer != null && importer.alphaIsTransparency);
            manifest.Key("source"); manifest.Value(assetPath ?? "");
            manifest.EndObject();
        }

        // -------------------------------------------------------------------------
        // glTF builder
        // -------------------------------------------------------------------------

        sealed class GltfBuilder
        {
            readonly string _name;
            readonly MemoryStream _bin = new();
            readonly BinaryWriter _bw;
            readonly List<string> _bufferViews = new();
            readonly List<string> _accessors = new();
            readonly List<NodeRec> _nodes = new();
            readonly List<string> _meshes = new();
            readonly List<string> _skins = new();
            readonly List<AnimRec> _anims = new();
            int _sceneRoot;

            class NodeRec
            {
                public string Name;
                public Vector3 T;
                public Quaternion R;
                public Vector3 S;
                public List<int> Children = new();
                public int Mesh = -1;
                public int Skin = -1;
            }

            class AnimRec
            {
                public string Name;
                public List<string> Samplers = new();
                public List<string> Channels = new();
            }

            public GltfBuilder(string name)
            {
                _name = name;
                _bw = new BinaryWriter(_bin);
            }

            public int AddNode(string name, Vector3 t, Quaternion r, Vector3 s)
            {
                _nodes.Add(new NodeRec { Name = name, T = t, R = r, S = s });
                return _nodes.Count - 1;
            }

            public void AddChild(int parent, int child) => _nodes[parent].Children.Add(child);
            public void SetSceneRoot(int n) => _sceneRoot = n;
            public void AttachMesh(int node, int mesh, int skin) { _nodes[node].Mesh = mesh; _nodes[node].Skin = skin; }

            public int AddSkin(string name, int[] joints, Matrix4x4[] ibms, int? skeletonRoot)
            {
                var floats = new float[ibms.Length * 16];
                for (var i = 0; i < ibms.Length; i++)
                {
                    var m = ibms[i];
                    var o = i * 16;
                    // glTF matrices are column-major.
                    for (var c = 0; c < 4; c++)
                        for (var r = 0; r < 4; r++)
                            floats[o + c * 4 + r] = m[r, c];
                }
                var acc = AddAccessor(floats, 16, "MAT4", 5126, null, null);
                var sb = new StringBuilder();
                sb.Append("{\"name\":").Append(Q(name)).Append(",\"inverseBindMatrices\":").Append(acc);
                if (skeletonRoot.HasValue) sb.Append(",\"skeleton\":").Append(skeletonRoot.Value);
                sb.Append(",\"joints\":[");
                for (var i = 0; i < joints.Length; i++) { if (i > 0) sb.Append(','); sb.Append(joints[i]); }
                sb.Append("]}");
                _skins.Add(sb.ToString());
                return _skins.Count - 1;
            }

            public int AddSkinnedMesh(Mesh mesh, int[] boneRemap, List<string> materialIds, ExportContext ctx)
            {
                var verts = mesh.vertices;
                var n = verts.Length;
                var normals = mesh.normals;
                var tangents = mesh.tangents;
                var colors = mesh.colors;
                var uv0 = new List<Vector2>(); mesh.GetUVs(0, uv0);
                var uv1 = new List<Vector2>(); mesh.GetUVs(1, uv1);
                var weights = mesh.boneWeights;

                var pos = new float[n * 3];
                var min = new Vector3(float.MaxValue, float.MaxValue, float.MaxValue);
                var max = new Vector3(float.MinValue, float.MinValue, float.MinValue);
                for (var i = 0; i < n; i++)
                {
                    var v = MV(verts[i]);
                    pos[i * 3] = v.x; pos[i * 3 + 1] = v.y; pos[i * 3 + 2] = v.z;
                    min = Vector3.Min(min, v); max = Vector3.Max(max, v);
                }
                var attrs = new StringBuilder();
                attrs.Append("\"POSITION\":").Append(AddAccessor(pos, 3, "VEC3", 5126, 34962, (min, max)));

                if (normals != null && normals.Length == n)
                {
                    var arr = new float[n * 3];
                    for (var i = 0; i < n; i++)
                    {
                        var v = MV(normals[i]).normalized;
                        arr[i * 3] = v.x; arr[i * 3 + 1] = v.y; arr[i * 3 + 2] = v.z;
                    }
                    attrs.Append(",\"NORMAL\":").Append(AddAccessor(arr, 3, "VEC3", 5126, 34962, null));
                }
                if (tangents != null && tangents.Length == n)
                {
                    var arr = new float[n * 4];
                    for (var i = 0; i < n; i++)
                    {
                        var t = tangents[i];
                        var v = MV(new Vector3(t.x, t.y, t.z)).normalized;
                        arr[i * 4] = v.x; arr[i * 4 + 1] = v.y; arr[i * 4 + 2] = v.z;
                        arr[i * 4 + 3] = -Mathf.Sign(t.w == 0f ? 1f : t.w); // mirror flips bitangent handedness
                    }
                    attrs.Append(",\"TANGENT\":").Append(AddAccessor(arr, 4, "VEC4", 5126, 34962, null));
                }
                if (uv0.Count == n)
                {
                    var arr = new float[n * 2];
                    for (var i = 0; i < n; i++) { arr[i * 2] = uv0[i].x; arr[i * 2 + 1] = 1f - uv0[i].y; }
                    attrs.Append(",\"TEXCOORD_0\":").Append(AddAccessor(arr, 2, "VEC2", 5126, 34962, null));
                }
                if (uv1.Count == n)
                {
                    var arr = new float[n * 2];
                    for (var i = 0; i < n; i++) { arr[i * 2] = uv1[i].x; arr[i * 2 + 1] = 1f - uv1[i].y; }
                    attrs.Append(",\"TEXCOORD_1\":").Append(AddAccessor(arr, 2, "VEC2", 5126, 34962, null));
                }
                if (colors != null && colors.Length == n)
                {
                    var arr = new float[n * 4];
                    for (var i = 0; i < n; i++) { arr[i * 4] = colors[i].r; arr[i * 4 + 1] = colors[i].g; arr[i * 4 + 2] = colors[i].b; arr[i * 4 + 3] = colors[i].a; }
                    attrs.Append(",\"COLOR_0\":").Append(AddAccessor(arr, 4, "VEC4", 5126, 34962, null));
                }
                if (weights != null && weights.Length == n)
                {
                    var joints = new ushort[n * 4];
                    var w = new float[n * 4];
                    for (var i = 0; i < n; i++)
                    {
                        var bw = weights[i];
                        var sum = bw.weight0 + bw.weight1 + bw.weight2 + bw.weight3;
                        if (sum <= 0f) { sum = 1f; bw.weight0 = 1f; }
                        joints[i * 4] = (ushort)Remap(boneRemap, bw.boneIndex0);
                        joints[i * 4 + 1] = (ushort)Remap(boneRemap, bw.boneIndex1);
                        joints[i * 4 + 2] = (ushort)Remap(boneRemap, bw.boneIndex2);
                        joints[i * 4 + 3] = (ushort)Remap(boneRemap, bw.boneIndex3);
                        w[i * 4] = bw.weight0 / sum; w[i * 4 + 1] = bw.weight1 / sum; w[i * 4 + 2] = bw.weight2 / sum; w[i * 4 + 3] = bw.weight3 / sum;
                    }
                    attrs.Append(",\"JOINTS_0\":").Append(AddAccessorU16(joints, 4, "VEC4"));
                    attrs.Append(",\"WEIGHTS_0\":").Append(AddAccessor(w, 4, "VEC4", 5126, 34962, null));
                }

                var prims = new StringBuilder();
                for (var s = 0; s < mesh.subMeshCount; s++)
                {
                    var tris = mesh.GetTriangles(s);
                    // Mirror flips handedness → reverse winding to keep front faces front.
                    var idx = new uint[tris.Length];
                    for (var t = 0; t + 2 < tris.Length; t += 3)
                    {
                        idx[t] = (uint)tris[t];
                        idx[t + 1] = (uint)tris[t + 2];
                        idx[t + 2] = (uint)tris[t + 1];
                    }
                    var accIdx = AddAccessorU32(idx);
                    if (s > 0) prims.Append(',');
                    prims.Append("{\"attributes\":{").Append(attrs).Append("},\"indices\":").Append(accIdx).Append(",\"mode\":4");
                    var matName = s < materialIds.Count ? materialIds[s] : "";
                    prims.Append(",\"extras\":{\"material_id\":").Append(Q(matName)).Append('}');
                    prims.Append('}');
                }
                _meshes.Add("{\"name\":" + Q(mesh.name) + ",\"primitives\":[" + prims + "]}");
                return _meshes.Count - 1;
            }

            static int Remap(int[] remap, int i) => i >= 0 && i < remap.Length ? remap[i] : 0;

            public int BeginAnimation(string name)
            {
                _anims.Add(new AnimRec { Name = name });
                return _anims.Count - 1;
            }

            public void AddChannel(int anim, int node, string path, float[] times, Vector3[] values, bool constant)
            {
                var a = _anims[anim];
                float[] tArr; float[] vArr;
                if (constant)
                {
                    tArr = new[] { times[0], times[times.Length - 1] };
                    vArr = new[] { values[0].x, values[0].y, values[0].z, values[0].x, values[0].y, values[0].z };
                }
                else
                {
                    tArr = times;
                    vArr = new float[values.Length * 3];
                    for (var i = 0; i < values.Length; i++) { vArr[i * 3] = values[i].x; vArr[i * 3 + 1] = values[i].y; vArr[i * 3 + 2] = values[i].z; }
                }
                var input = AddAccessor(tArr, 1, "SCALAR", 5126, null, (new Vector3(tArr[0], 0, 0), new Vector3(tArr[tArr.Length - 1], 0, 0)), true);
                var output = AddAccessor(vArr, 3, "VEC3", 5126, null, null);
                a.Samplers.Add("{\"input\":" + input + ",\"output\":" + output + ",\"interpolation\":\"LINEAR\"}");
                a.Channels.Add("{\"sampler\":" + (a.Samplers.Count - 1) + ",\"target\":{\"node\":" + node + ",\"path\":\"" + path + "\"}}");
            }

            public void AddChannel(int anim, int node, string path, float[] times, Quaternion[] values, bool constant)
            {
                var a = _anims[anim];
                float[] tArr; float[] vArr;
                if (constant)
                {
                    tArr = new[] { times[0], times[times.Length - 1] };
                    var q = values[0].normalized;
                    vArr = new[] { q.x, q.y, q.z, q.w, q.x, q.y, q.z, q.w };
                }
                else
                {
                    tArr = times;
                    vArr = new float[values.Length * 4];
                    for (var i = 0; i < values.Length; i++)
                    {
                        var q = values[i].normalized;
                        vArr[i * 4] = q.x; vArr[i * 4 + 1] = q.y; vArr[i * 4 + 2] = q.z; vArr[i * 4 + 3] = q.w;
                    }
                }
                var input = AddAccessor(tArr, 1, "SCALAR", 5126, null, (new Vector3(tArr[0], 0, 0), new Vector3(tArr[tArr.Length - 1], 0, 0)), true);
                var output = AddAccessor(vArr, 4, "VEC4", 5126, null, null);
                a.Samplers.Add("{\"input\":" + input + ",\"output\":" + output + ",\"interpolation\":\"LINEAR\"}");
                a.Channels.Add("{\"sampler\":" + (a.Samplers.Count - 1) + ",\"target\":{\"node\":" + node + ",\"path\":\"" + path + "\"}}");
            }

            int AddBufferView(byte[] bytes, int? target)
            {
                Align4();
                var offset = (int)_bin.Length;
                _bw.Write(bytes);
                var sb = new StringBuilder();
                sb.Append("{\"buffer\":0,\"byteOffset\":").Append(offset).Append(",\"byteLength\":").Append(bytes.Length);
                if (target.HasValue) sb.Append(",\"target\":").Append(target.Value);
                sb.Append('}');
                _bufferViews.Add(sb.ToString());
                return _bufferViews.Count - 1;
            }

            void Align4()
            {
                while (_bin.Length % 4 != 0) _bw.Write((byte)0);
            }

            int AddAccessor(float[] data, int comps, string type, int componentType, int? target, (Vector3 min, Vector3 max)? minmax, bool scalarMinMax = false)
            {
                var bytes = new byte[data.Length * 4];
                Buffer.BlockCopy(data, 0, bytes, 0, bytes.Length);
                var bv = AddBufferView(bytes, target);
                var sb = new StringBuilder();
                sb.Append("{\"bufferView\":").Append(bv).Append(",\"componentType\":").Append(componentType);
                sb.Append(",\"count\":").Append(data.Length / comps).Append(",\"type\":\"").Append(type).Append('"');
                if (minmax.HasValue)
                {
                    var (mn, mx) = minmax.Value;
                    if (scalarMinMax)
                        sb.Append(",\"min\":[").Append(F(mn.x)).Append("],\"max\":[").Append(F(mx.x)).Append(']');
                    else
                        sb.Append(",\"min\":[").Append(F(mn.x)).Append(',').Append(F(mn.y)).Append(',').Append(F(mn.z))
                          .Append("],\"max\":[").Append(F(mx.x)).Append(',').Append(F(mx.y)).Append(',').Append(F(mx.z)).Append(']');
                }
                sb.Append('}');
                _accessors.Add(sb.ToString());
                return _accessors.Count - 1;
            }

            int AddAccessorU16(ushort[] data, int comps, string type)
            {
                var bytes = new byte[data.Length * 2];
                Buffer.BlockCopy(data, 0, bytes, 0, bytes.Length);
                var bv = AddBufferView(bytes, 34962);
                _accessors.Add("{\"bufferView\":" + bv + ",\"componentType\":5123,\"count\":" + (data.Length / comps) + ",\"type\":\"" + type + "\"}");
                return _accessors.Count - 1;
            }

            int AddAccessorU32(uint[] data)
            {
                var bytes = new byte[data.Length * 4];
                Buffer.BlockCopy(data, 0, bytes, 0, bytes.Length);
                var bv = AddBufferView(bytes, 34963);
                _accessors.Add("{\"bufferView\":" + bv + ",\"componentType\":5125,\"count\":" + data.Length + ",\"type\":\"SCALAR\"}");
                return _accessors.Count - 1;
            }

            public void WriteGlb(string path)
            {
                Align4();
                var json = new StringBuilder();
                json.Append("{\"asset\":{\"version\":\"2.0\",\"generator\":\"AxieGltfExporter\"},");
                json.Append("\"scene\":0,\"scenes\":[{\"name\":").Append(Q(_name)).Append(",\"nodes\":[").Append(_sceneRoot).Append("]}],");
                json.Append("\"nodes\":[");
                for (var i = 0; i < _nodes.Count; i++)
                {
                    var n = _nodes[i];
                    if (i > 0) json.Append(',');
                    json.Append("{\"name\":").Append(Q(n.Name));
                    json.Append(",\"translation\":[").Append(F(n.T.x)).Append(',').Append(F(n.T.y)).Append(',').Append(F(n.T.z)).Append(']');
                    var q = n.R.normalized;
                    json.Append(",\"rotation\":[").Append(F(q.x)).Append(',').Append(F(q.y)).Append(',').Append(F(q.z)).Append(',').Append(F(q.w)).Append(']');
                    json.Append(",\"scale\":[").Append(F(n.S.x)).Append(',').Append(F(n.S.y)).Append(',').Append(F(n.S.z)).Append(']');
                    if (n.Children.Count > 0)
                    {
                        json.Append(",\"children\":[");
                        for (var c = 0; c < n.Children.Count; c++) { if (c > 0) json.Append(','); json.Append(n.Children[c]); }
                        json.Append(']');
                    }
                    if (n.Mesh >= 0) json.Append(",\"mesh\":").Append(n.Mesh);
                    if (n.Skin >= 0) json.Append(",\"skin\":").Append(n.Skin);
                    json.Append('}');
                }
                json.Append(']');
                if (_meshes.Count > 0) json.Append(",\"meshes\":[").Append(string.Join(",", _meshes)).Append(']');
                if (_skins.Count > 0) json.Append(",\"skins\":[").Append(string.Join(",", _skins)).Append(']');
                if (_anims.Count > 0)
                {
                    json.Append(",\"animations\":[");
                    for (var i = 0; i < _anims.Count; i++)
                    {
                        var a = _anims[i];
                        if (i > 0) json.Append(',');
                        json.Append("{\"name\":").Append(Q(a.Name));
                        json.Append(",\"samplers\":[").Append(string.Join(",", a.Samplers)).Append(']');
                        json.Append(",\"channels\":[").Append(string.Join(",", a.Channels)).Append("]}");
                    }
                    json.Append(']');
                }
                json.Append(",\"accessors\":[").Append(string.Join(",", _accessors)).Append(']');
                json.Append(",\"bufferViews\":[").Append(string.Join(",", _bufferViews)).Append(']');
                json.Append(",\"buffers\":[{\"byteLength\":").Append(_bin.Length).Append("}]}");

                var jsonBytes = Encoding.UTF8.GetBytes(json.ToString());
                var jsonPad = (4 - jsonBytes.Length % 4) % 4;
                var binBytes = _bin.ToArray();
                var total = 12 + 8 + jsonBytes.Length + jsonPad + 8 + binBytes.Length;

                Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
                using var fs = new FileStream(path, FileMode.Create, FileAccess.Write);
                using var w = new BinaryWriter(fs);
                w.Write(0x46546C67u); // glTF
                w.Write(2u);
                w.Write((uint)total);
                w.Write((uint)(jsonBytes.Length + jsonPad));
                w.Write(0x4E4F534Au); // JSON
                w.Write(jsonBytes);
                for (var i = 0; i < jsonPad; i++) w.Write((byte)0x20);
                w.Write((uint)binBytes.Length);
                w.Write(0x004E4942u); // BIN
                w.Write(binBytes);
            }

            static string F(float v)
            {
                if (float.IsNaN(v) || float.IsInfinity(v)) v = 0f;
                return v.ToString("R", CultureInfo.InvariantCulture);
            }

            static string Q(string s)
            {
                var sb = new StringBuilder("\"");
                foreach (var c in s ?? "")
                {
                    switch (c)
                    {
                        case '"': sb.Append("\\\""); break;
                        case '\\': sb.Append("\\\\"); break;
                        case '\n': sb.Append("\\n"); break;
                        case '\r': sb.Append("\\r"); break;
                        case '\t': sb.Append("\\t"); break;
                        default:
                            if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                            else sb.Append(c);
                            break;
                    }
                }
                return sb.Append('"').ToString();
            }
        }

        // -------------------------------------------------------------------------
        // Helpers
        // -------------------------------------------------------------------------

        class ExportContext
        {
            public readonly Dictionary<string, Material> Materials = new();
            public readonly Dictionary<string, Texture> Textures = new();
            readonly Dictionary<int, string> _ids = new();

            public string Id(UnityEngine.Object obj)
            {
                if (obj == null) return "";
                var iid = obj.GetInstanceID();
                if (_ids.TryGetValue(iid, out var cached)) return cached;
                if (AssetDatabase.TryGetGUIDAndLocalFileIdentifier(obj, out string guid, out long localId) && !string.IsNullOrEmpty(guid))
                    cached = guid + "_" + localId.ToString(CultureInfo.InvariantCulture);
                else
                {
                    var assetPath = AssetDatabase.GetAssetPath(obj);
                    cached = Sanitize((string.IsNullOrEmpty(assetPath) ? obj.name : assetPath) + "_" + iid);
                }
                _ids[iid] = cached;
                return cached;
            }

            public void EnqueueMaterial(Material m) { if (m != null) Materials[Id(m)] = m; }
            public void EnqueueTexture(Texture t) { if (t != null && !(t is RenderTexture)) Textures[Id(t)] = t; }
        }

        static T ReadField<T>(object obj, string name)
        {
            var field = obj.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
            if (field == null) return default;
            var value = field.GetValue(obj);
            return value is T typed ? typed : default;
        }

        static string Sanitize(string s)
        {
            var sb = new StringBuilder(s.Length);
            foreach (var c in s)
                sb.Append(char.IsLetterOrDigit(c) || c == '_' || c == '-' ? c : '_');
            return sb.ToString();
        }

        static void WriteVec2(JsonWriter j, Vector2 v) { j.BeginArray(); j.Value(v.x); j.Value(v.y); j.EndArray(); }
        static void WriteVec3(JsonWriter j, Vector3 v) { j.BeginArray(); j.Value(v.x); j.Value(v.y); j.Value(v.z); j.EndArray(); }
        static void WriteVec4(JsonWriter j, Vector4 v) { j.BeginArray(); j.Value(v.x); j.Value(v.y); j.Value(v.z); j.Value(v.w); j.EndArray(); }
        static void WriteQuat(JsonWriter j, Quaternion q) { j.BeginArray(); j.Value(q.x); j.Value(q.y); j.Value(q.z); j.Value(q.w); j.EndArray(); }
        static void WriteColor(JsonWriter j, Color c) { j.BeginArray(); j.Value(c.r); j.Value(c.g); j.Value(c.b); j.Value(c.a); j.EndArray(); }

        /// <summary>Minimal compact JSON writer with invariant-culture numbers.</summary>
        internal sealed class JsonWriter : IDisposable
        {
            readonly TextWriter _w;
            readonly Stack<bool> _needsComma = new();
            bool _pendingValue;

            public JsonWriter(TextWriter w)
            {
                _w = w;
                _needsComma.Push(false);
            }

            void Sep()
            {
                if (_pendingValue) { _pendingValue = false; return; }
                if (_needsComma.Peek()) _w.Write(',');
                _needsComma.Pop();
                _needsComma.Push(true);
            }

            public void BeginObject() { Sep(); _w.Write('{'); _needsComma.Push(false); }
            public void EndObject() { _needsComma.Pop(); _w.Write('}'); }
            public void BeginArray() { Sep(); _w.Write('['); _needsComma.Push(false); }
            public void EndArray() { _needsComma.Pop(); _w.Write(']'); }

            public void Key(string key)
            {
                Sep();
                WriteString(key);
                _w.Write(':');
                _pendingValue = true;
            }

            public void Value(string s) { Sep(); WriteString(s); }
            public void ValueNull() { Sep(); _w.Write("null"); }
            public void Value(bool v) { Sep(); _w.Write(v ? "true" : "false"); }
            public void Value(int v) { Sep(); _w.Write(v.ToString(CultureInfo.InvariantCulture)); }
            public void Value(float v)
            {
                Sep();
                if (float.IsNaN(v) || float.IsInfinity(v)) v = 0f;
                _w.Write(v.ToString("R", CultureInfo.InvariantCulture));
            }

            void WriteString(string s)
            {
                _w.Write('"');
                foreach (var c in s ?? "")
                {
                    switch (c)
                    {
                        case '"': _w.Write("\\\""); break;
                        case '\\': _w.Write("\\\\"); break;
                        case '\n': _w.Write("\\n"); break;
                        case '\r': _w.Write("\\r"); break;
                        case '\t': _w.Write("\\t"); break;
                        default:
                            if (c < 0x20) _w.Write("\\u" + ((int)c).ToString("x4"));
                            else _w.Write(c);
                            break;
                    }
                }
                _w.Write('"');
            }

            public void Dispose() => _w.Flush();
        }
    }
}
