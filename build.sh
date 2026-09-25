#!/bin/bash

set -e

rm -rf app
mkdir -p app
cp -rf config.xml index.html network_security_config.xml app

# Plugin de PiP nativo: acha a pasta que tem o plugin.xml (funciona mesmo se o
# zip foi extraído numa pasta com o mesmo nome, ex: pasta/pasta/plugin.xml).
# (procura pelo package.json: pasta antiga extraída sem ele é ignorada)
PIP_XML="$(find . -path ./app -prune -o -name package.json -path '*cordova-plugin-manager-pip*' -print | head -1)"
if [ -n "$PIP_XML" ]; then
  cp -rf "$(dirname "$PIP_XML")" app/cordova-plugin-manager-pip
  echo "🖼️ Plugin de PiP encontrado em: $(dirname "$PIP_XML")"
else
  echo "⚠️ Plugin de PiP não encontrado (cordova-plugin-manager-pip/plugin.xml) — o APK sai sem PiP nativo."
fi
PROJECT_NAME="Manager"
APP_ID="com.Manager.Manager"
WORKDIR="$(pwd)/app"
APK_FILE_NAME="Manager.apk"

echo "📦 Iniciando build APK com Cordova + Docker..."

docker run --network host --rm -it \
  -v "$WORKDIR":/workspace \
  beevelop/cordova \
  bash -c "
    set -e

    rm -rf /tmp/app
    echo '🚧 Criando projeto Cordova...'
    npm config set strict-ssl false &&
    export NODE_TLS_REJECT_UNAUTHORIZED=0

    echo '🔨 Forçando uso de Gradle cache...'

    cordova create app $APP_ID $PROJECT_NAME

    cd app
    
    cordova plugin add cordova-plugin-whitelist

    echo '🖼️ Adicionando PiP nativo...'
    if [ -f /workspace/cordova-plugin-manager-pip/plugin.xml ]; then
      cordova plugin add /workspace/cordova-plugin-manager-pip
    fi

    cp -rf /workspace/config.xml ./

    sed -i 's|<name>.*</name>|<name>$PROJECT_NAME</name>|g' config.xml


    echo ok
    cat config.xml
    echo ok

    echo '🧹 Limpando www...'
    rm -rf www/*

    echo '📄 Copiando arquivos...'
    cp /workspace/index.html www/
    cp /workspace/script.sh www/ 2>/dev/null || true

    echo '📱 Adicionando Android...'
    cordova platform add android

    # sleep 900
    echo '🔨 Gerando APK...'
    cordova build android

    echo '📦 Copiando APK para workspace...'
    cp -rf platforms/android/app/build/outputs/apk/debug/app-debug.apk /workspace/$APK_FILE_NAME 2>/dev/null || \
    cp -rf platforms/android/build/outputs/apk/debug/app-debug.apk /workspace/$APK_FILE_NAME

    echo '✅ Build finalizado!'
  "

ls
cp -rf app/*.apk ./
rm -rf app

echo "🎉 APK gerado na pasta atual: $APK_FILE_NAME"
