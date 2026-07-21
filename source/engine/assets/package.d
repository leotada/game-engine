/// Asset loaders — disk-to-engine pipelines for textures and meshes.
module engine.assets;

// asset_file is Stream E; gated so other configs can exclude a WIP module.
version (NoAssetFile) {
} else {
    public import engine.assets.asset_file;
}
public import engine.assets.bmp;
public import engine.assets.gltf;
