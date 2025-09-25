# Full Flutter + Gradle clean
Write-Output "Cleaning Flutter & Gradle caches..."

# Clean Flutter build artifacts
flutter clean

# Delete extra build caches
Remove-Item -Recurse -Force .dart_tool -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force build -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force android\build -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force android\.gradle -ErrorAction SilentlyContinue

# Optional: clear Gradle cache from user home (forces redownload of dependencies)
# Comment this out if you want to keep cache
# Remove-Item -Recurse -Force $env:USERPROFILE\.gradle\caches -ErrorAction SilentlyContinue

Write-Output "✅ Project fully cleaned. Run 'flutter pub get' next."
