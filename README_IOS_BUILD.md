# Fix iOS Build - Agora RTC Engine

## Problema
Error al compilar iOS en Codemagic:
```
Lexical or Preprocessor Issue (Xcode): 'AgoraRtcWrapper/AgoraPIPController.h' file not found
```

## Solución Implementada

### 1. Actualización de `ios/Podfile`
Se agregó configuración específica para Agora RTC Engine en el `post_install`:

```ruby
# Agora RTC Engine fix
config.build_settings['BUILD_LIBRARY_FOR_DISTRIBUTION'] = 'YES'
config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'arm64'

# Agora RTC Engine: Ensure static libraries are properly linked
installer.pods_project.build_configurations.each do |config|
  config.build_settings['CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES'] = 'YES'
end
```

### 2. Actualización de `codemagic.yaml`
Se modificó el workflow para limpiar pods antes de instalar:

```yaml
- name: Clean and Install CocoaPods
  script: |
    cd ios
    rm -rf Pods Podfile.lock
    pod cache clean --all
    pod install --repo-update
    cd ..
```

## Para Compilar en Codemagic

1. **Hacer nuevo build desde GitHub:**
   - Branch: `master`
   - Commit: `037c02a` o más reciente
   
2. **El workflow automáticamente:**
   - Limpiará pods antiguos
   - Instalará pods frescos con `--repo-update`
   - Compilará iOS con las configuraciones correctas de Agora

3. **Si persiste el error:**
   - Verificar que Xcode latest esté disponible
   - Asegurar que CocoaPods esté actualizado
   - Revisar logs de `pod install` para errores específicos

## Versión Actual
- **v3.13.0 build 210**
- Incluye todos los cambios de Android (emojis WhatsApp, radio walkie-talkie, etc.)

## Commits Relevantes
- `037c02a` - iOS fix: Configurar Podfile para Agora RTC Engine + limpieza de pods
- `884657f` - v3.13.0: Versión sincronizada Android/iOS
- `2ba6b40` - v3.12.9: Nuevas features (emoji picker, radio persistente)
