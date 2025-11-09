# MLC Chat iOS Deployment Guide
## MacBook M1 Air → iPhone 16 Pro

### Prerequisites
- MacBook M1 Air with macOS
- iPhone 16 Pro
- Apple Developer Account (free or paid)
- Xcode installed from App Store

### Step 1: Install Dependencies

#### Install MLC LLM Python Package
```bash
# Create conda environment
conda create --name mlc-prebuilt python=3.13
conda activate mlc-prebuilt

# Install MLC LLM packages
python -m pip install --pre -U -f https://mlc.ai/wheels mlc-llm-nightly-cpu mlc-ai-nightly-cpu

# Install git-lfs for model downloads
conda install -c conda-forge git-lfs
```

#### Verify Installation
```bash
mlc_llm --help
```

### Step 2: Build Model Libraries

#### Navigate to iOS Project
```bash
cd /Users/azula/Documents/t-effi/mlc-llm/ios/MLCChat
```

#### Set Environment Variable
```bash
export MLC_LLM_SOURCE_DIR=/Users/azula/Documents/t-effi/mlc-llm
```

#### Build Models
```bash
python -m mlc_llm package
```

This will:
- Download Qwen3-0.6B-q0f16-MLC, Qwen3-1.7B-q4f16_1-MLC and TinyLLM models
- Compile them for iPhone
- Generate runtime libraries (~3GB total)

### Step 3: Configure Xcode Project

#### Open Xcode Project
```bash
open MLCChat.xcodeproj
```

#### Configure Signing & Capabilities
1. Select "MLCChat" project in navigator
2. Go to "Signing & Capabilities" tab
3. Set your Apple Developer Team
4. Change Bundle Identifier to something unique (e.g., `com.yourname.mlcchat`)

#### Device Configuration
1. Connect iPhone 16 Pro via USB
2. Trust computer on iPhone when prompted
3. Select iPhone 16 Pro as target device in Xcode

### Step 4: Build & Deploy

#### Build for Device
1. Select "Any iOS Device (arm64)" or your iPhone 16 Pro
2. Click "Build" (⌘+B) to compile
3. Wait for build to complete (~5-10 minutes first time)

#### Deploy to iPhone
1. Click "Run" button (▶️) or press ⌘+R
2. Xcode will install app on your iPhone
3. Trust developer certificate on iPhone: Settings → General → VPN & Device Management

### Step 5: Optional - Bundle Model Weights

To include models in the app (larger download but faster startup):

#### Edit Configuration
```bash
# Edit mlc-package-config.json
nano mlc-package-config.json
```

Add `"bundle_weight": true` to desired models:
```json
{
    "model": "HF://mlc-ai/Qwen3-0.6B-q0f16-MLC",
    "model_id": "Qwen3-0.6B-q0f16-MLC",
    "bundle_weight": true,
    "estimated_vram_bytes": 3000000000,
    "overrides": {
        "prefill_chunk_size": 128,
        "context_window_size": 2048
    }
}
```

#### Rebuild
```bash
mlc_llm package
```

### Troubleshooting

#### Build Errors
- **"No such file or directory"**: Run `mlc_llm package` first
- **Signing errors**: Check Apple Developer account and bundle ID
- **Device not recognized**: Trust computer on iPhone

#### Performance Issues
- Use Qwen3-0.6B-q0f16-MLC for better performance
- Reduce `context_window_size` in config if needed
- Close other apps on iPhone during inference

#### Storage Requirements
- Models: ~3GB
- App bundle: ~100MB
- Total iPhone storage needed: ~4GB

### Expected Results
- App launches on iPhone 16 Pro
- Models load in ~30 seconds (first time)
- Inference speed: ~10-20 tokens/second
- Memory usage: ~2-3GB RAM

### Next Steps
- Test different models by modifying `mlc-package-config.json`
- Experiment with quantization settings
- Consider bundling weights for offline use
