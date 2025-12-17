#!/bin/bash
set -e

# Script to deploy the frontend build to GitHub Pages
# This copies the build output from frontend/dist/ to the gh-pages branch

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "🚀 Deploying to GitHub Pages..."

# Build the frontend
echo "📦 Building frontend..."
cd frontend
npm run build
cd ..

# Get current branch
CURRENT_BRANCH=$(git branch --show-current)
echo "📍 Current branch: $CURRENT_BRANCH"

# Stash any uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo "⚠️  Warning: You have uncommitted changes. Stashing them..."
    git stash
    STASHED=true
else
    STASHED=false
fi

# Checkout gh-pages branch
echo "📂 Checking out gh-pages branch..."
git checkout gh-pages

# Remove old build files (but keep non-build files like challenges/, drafts/, etc.)
echo "🧹 Cleaning old build files..."
# Remove HTML files and directories that are part of the build
rm -rf index.html 404.html search.html search.json
rm -rf category/ solutions/ search/ _astro/

# Copy new build files from frontend/dist/
echo "📋 Copying new build files..."
cp -r frontend/dist/* .

# Ensure .nojekyll exists (needed for GitHub Pages to serve files starting with _)
touch .nojekyll

# Stage all changes
echo "📝 Staging changes..."
git add -A

# Check if there are changes to commit
if git diff --staged --quiet; then
    echo "✅ No changes to commit. Build is already up to date."
else
    # Commit changes
    echo "💾 Committing changes..."
    git commit -m "Deploy: Update site with correct base path URLs

- Rebuild frontend with base: /system-design-atlas/
- Fix URLs to include /system-design-atlas/ prefix
- Generated at $(date -u +"%Y-%m-%d %H:%M:%S UTC")"

    # Push to gh-pages
    echo "🚀 Pushing to gh-pages branch..."
    git push origin gh-pages
    echo "✅ Deployment complete!"
fi

# Switch back to original branch
echo "🔄 Switching back to $CURRENT_BRANCH branch..."
git checkout "$CURRENT_BRANCH"

# Restore stashed changes if any
if [ "$STASHED" = true ]; then
    echo "📦 Restoring stashed changes..."
    git stash pop
fi

echo "✨ Done! Your site should be live at https://doda.co/system-design-atlas/ in a few moments."

