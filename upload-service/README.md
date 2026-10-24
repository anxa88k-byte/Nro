# IPA Forge upload service

The static `index.html` page sends a project ZIP or RAR here. This service stores the archive temporarily and dispatches `.github/workflows/ios-ipa.yml`; the macOS runner downloads and extracts it into a temporary build workspace. RAR extraction installs `unar` on the runner.

## Configure GitHub

1. Deploy this folder as a single HTTPS service with persistent storage mounted at `/data` (or set `UPLOAD_DIR`). Keep one instance, or use a shared volume when scaling.
2. Set the environment values from `.env.example`. `GITHUB_TOKEN` needs Actions write access for the configured repository. `IPA_UPLOAD_TOKEN` is entered on the web page; `UPLOAD_SERVICE_TOKEN` is only used between the service and Actions. Generate separate random values for both.
3. Add repository Actions secrets `UPLOAD_SERVICE_URL` (the service's HTTPS base URL) and `UPLOAD_SERVICE_TOKEN` (same value as the service setting). Add `DEVELOPMENT_TEAM` if signed builds are needed; set the `BUNDLE_ID` repository variable as needed.
4. Set `ALLOWED_ORIGINS` to the exact HTTPS origin hosting `index.html`, without a path. Set `GITHUB_REPOSITORY` to `owner/repository` and `GITHUB_REF` to the branch containing the workflow.
5. Open the hosted `index.html`, enter the service URL and upload key, choose an Xcode ZIP or RAR, enter the desired IPA filename (without `.ipa`), then select the signing mode and start the build. Download the IPA from the run's Artifacts section.

The configured GitHub token is stored only by the service. The page keeps its upload key for the current browser tab only. The runner deletes a ZIP after downloading it; uploads that never get downloaded expire after 24 hours by default. Change `UPLOAD_TTL_SECONDS` to adjust retention. The temporary ZIP is not committed to the source repository.

Uploaded Xcode projects execute build scripts on the macOS runner. Only accept source you trust. The `unsigned` mode does not need an Apple team; signed modes require the repository's signing configuration.

The name field sets the `.ipa` output filename and artifact label. It does not create a GitHub repository; the GitHub profile prefix on the page is a label. If the output path already contains that filename during the same build, the script adds `-2`, `-3`, and so on.
