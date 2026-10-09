using UnityEditor;
using UnityEngine;
namespace Soaring.Editor
{
    public sealed class UIArtImporter : AssetPostprocessor
    {
        void OnPreprocessTexture()
        {
            if (!assetPath.StartsWith("Assets/Soaring/Resources/UI/Art/")) return;
            var texture = (TextureImporter)assetImporter;
            texture.textureType = TextureImporterType.Sprite;
            texture.spritePixelsPerUnit = 1000;
            texture.spriteImportMode = SpriteImportMode.Single;
            texture.alphaIsTransparency = true;
            texture.mipmapEnabled = false;
            texture.wrapMode = TextureWrapMode.Clamp;
            texture.filterMode = FilterMode.Bilinear;
            texture.maxTextureSize = 1024;
            texture.textureCompression = TextureImporterCompression.Uncompressed;
            // UI faces the eye directly; keep fine strokes at full resolution.
            texture.SetPlatformTextureSettings(new TextureImporterPlatformSettings {
                name = "Android", overridden = true, maxTextureSize = 1024,
                format = TextureImporterFormat.ASTC_4x4, compressionQuality = 100
            });
        }
    }
}
