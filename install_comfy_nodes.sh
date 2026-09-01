#!/usr/bin/env bash

set -u

CONTAINER="comfyui-docker"
CUSTOM_NODES="/basedir/custom_nodes"
VENV="/comfy/mnt/venv"
PIP="$VENV/bin/pip"
NODE_LIST="$(dirname "$0")/nodes.txt"

echo "=========================================="
echo " ComfyUI Custom Nodes Installer / Updater"
echo "=========================================="
echo "Container  : $CONTAINER"
echo "Directory  : $CUSTOM_NODES"
echo "Python venv: $VENV"
echo "List       : $NODE_LIST"
echo

# ------------------------------------------------------
# Проверки
# ------------------------------------------------------

if [[ ! -f "$NODE_LIST" ]]; then
    echo "ERROR: $NODE_LIST not found"
    exit 1
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "ERROR: Docker container '$CONTAINER' not found"
    exit 1
fi

if ! docker exec "$CONTAINER" test -x "$PIP"; then
    echo "ERROR: Python venv not found: $VENV"
    exit 1
fi

SUCCESS=0
FAILED=0
SKIPPED=0
CHANGED=0


# ------------------------------------------------------
# Обработка nodes.txt
# ------------------------------------------------------

while IFS= read -r URL || [[ -n "$URL" ]]; do

    # Убираем пробелы
    URL="$(echo "$URL" | xargs)"

    # Пропускаем пустые строки и комментарии
    [[ -z "$URL" ]] && continue
    [[ "$URL" =~ ^# ]] && continue

    NAME="$(basename "$URL" .git)"
    NODE_PATH="$CUSTOM_NODES/$NAME"

    echo
    echo "------------------------------------------"
    echo "NODE: $NAME"
    echo "URL : $URL"
    echo "------------------------------------------"


    # ==================================================
    # Нода уже установлена
    # ==================================================

    if docker exec "$CONTAINER" \
        test -d "$NODE_PATH/.git"; then

        echo "Already installed."
        echo "Checking for updates..."

        # Получаем текущий commit от пользователя comfy
        OLD_COMMIT="$(
            docker exec -u comfy "$CONTAINER" \
            bash -c "cd '$NODE_PATH' && git rev-parse HEAD" \
            2>/dev/null
        )"

        if [[ -z "$OLD_COMMIT" ]]; then
            echo "FAILED: cannot determine current commit"
            ((FAILED++))
            continue
        fi

        # git pull запускаем от comfy,
        # потому что репозиторий принадлежит comfy:comfy
        if docker exec -u comfy "$CONTAINER" \
            bash -c "cd '$NODE_PATH' && git pull --ff-only"; then

            # Получаем новый commit
            NEW_COMMIT="$(
                docker exec -u comfy "$CONTAINER" \
                bash -c "cd '$NODE_PATH' && git rev-parse HEAD" \
                2>/dev/null
            )"

            if [[ "$OLD_COMMIT" != "$NEW_COMMIT" ]]; then

                echo "UPDATED: $NAME"
                echo "Commit:"
                echo "  $OLD_COMMIT"
                echo "    ->"
                echo "  $NEW_COMMIT"

                CHANGED=1

                # После обновления устанавливаем зависимости
                if docker exec "$CONTAINER" \
                    test -f "$NODE_PATH/requirements.txt"; then

                    echo
                    echo "requirements.txt found."
                    echo "Installing dependencies..."

                    if docker exec -u root "$CONTAINER" \
                        bash -c "'$PIP' install -r '$NODE_PATH/requirements.txt'"; then

                        echo "Dependencies installed successfully."

                    else

                        echo "FAILED: requirements.txt for $NAME"
                        ((FAILED++))
                        continue

                    fi

                else

                    echo "No requirements.txt found."

                fi

            else

                echo "Already up to date: $NAME"

            fi

        else

            echo "FAILED: git pull"
            ((FAILED++))
            continue

        fi

        # На всякий случай возвращаем владельца
        docker exec -u root "$CONTAINER" \
            chown -R comfy:comfy "$NODE_PATH"

        ((SUCCESS++))

        continue
    fi


    # ==================================================
    # Каталог существует, но это не Git repository
    # ==================================================

    if docker exec "$CONTAINER" \
        test -e "$NODE_PATH"; then

        echo "WARNING: $NODE_PATH exists"
        echo "but is not a Git repository."
        echo "Skipping."

        ((SKIPPED++))
        continue
    fi


    # ==================================================
    # Новая нода
    # ==================================================

    echo "Not installed."
    echo "Cloning..."

    # Clone выполняем root, чтобы не было проблем
    # с правами на /basedir/custom_nodes
    if docker exec -u root "$CONTAINER" \
        bash -c "git clone '$URL' '$NODE_PATH'"; then

        echo "INSTALLED: $NAME"

        CHANGED=1

    else

        echo "FAILED: git clone"
        ((FAILED++))
        continue

    fi


    # --------------------------------------------------
    # requirements.txt
    # --------------------------------------------------

    if docker exec "$CONTAINER" \
        test -f "$NODE_PATH/requirements.txt"; then

        echo
        echo "requirements.txt found."
        echo "Installing dependencies..."

        if docker exec -u root "$CONTAINER" \
            bash -c "'$PIP' install -r '$NODE_PATH/requirements.txt'"; then

            echo "Dependencies installed successfully."

        else

            echo "FAILED: requirements.txt for $NAME"
            ((FAILED++))
            continue

        fi

    else

        echo "No requirements.txt found."

    fi


    # --------------------------------------------------
    # Возвращаем владельца
    # --------------------------------------------------

    docker exec -u root "$CONTAINER" \
        chown -R comfy:comfy "$NODE_PATH"

    ((SUCCESS++))

done < "$NODE_LIST"


# ------------------------------------------------------
# Итог
# ------------------------------------------------------

echo
echo "=========================================="
echo " RESULT"
echo "=========================================="
echo "Processed         : $SUCCESS"
echo "Failed            : $FAILED"
echo "Skipped           : $SKIPPED"
echo "Changes detected  : $CHANGED"
echo "=========================================="


# ------------------------------------------------------
# Restart
# ------------------------------------------------------

if [[ "$CHANGED" -eq 1 ]]; then

    echo
    echo "=========================================="
    echo " Restarting ComfyUI container..."
    echo "=========================================="

    if docker restart "$CONTAINER"; then

        echo
        echo "ComfyUI restarted successfully."
        echo "New/updated nodes and dependencies are loaded."

    else

        echo
        echo "ERROR: Failed to restart container."
        exit 1

    fi

else

    if [[ "$FAILED" -gt 0 ]]; then

        echo
        echo "Some nodes failed to install/update."
        echo "Container will not be restarted."

        exit 1
    fi

    echo
    echo "No changes detected."
    echo "Container will not be restarted."

fi
