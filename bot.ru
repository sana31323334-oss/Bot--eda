#!/usr/bin/env python3
"""
🛒 Телеграм-бот «Склад продуктов»
──────────────────────────────────
🟢 qty >= min  — в норме
🟡 0 < qty < min — мало
🔴 qty == 0    — нет

Установка:
    pip install "python-telegram-bot==20.7"

"""

import sqlite3
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, CallbackQueryHandler,
    MessageHandler, filters, ContextTypes, ConversationHandler,
)

# ─── Настройки ───────────────────────────────────────────────
BOT_TOKEN = "8635365140:AAFx_G2gadZfXAc7xczhnGHNcwgpPe3Ot2E"
DB_FILE   = "products.db"
# ─────────────────────────────────────────────────────────────

S_MENU, S_EDIT_QTY, S_EDIT_MIN, S_ADD_NAME, S_ADD_QTY, S_ADD_MIN, S_ADD_UNIT = range(7)


# ══════════════ БАЗА ДАННЫХ ══════════════════════════════════

def db():
    return sqlite3.connect(DB_FILE)

def db_init():
    with db() as c:
        c.execute("""CREATE TABLE IF NOT EXISTS products (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            name    TEXT UNIQUE NOT NULL,
            qty     REAL NOT NULL DEFAULT 0,
            min_qty REAL NOT NULL DEFAULT 1,
            unit    TEXT NOT NULL DEFAULT 'шт'
        )""")
        for row in [
            ("Молоко",    2,  3,  "л"),
            ("Хлеб",      0,  2,  "шт"),
            ("Яйца",     10, 12,  "шт"),
            ("Масло",     1,  2,  "пач"),
            ("Сахар",   500,300,  "г"),
            ("Кофе",      0,  1,  "пач"),
            ("Макароны",  3,  2,  "пач"),
            ("Рис",       0,  1,  "кг"),
        ]:
            c.execute("INSERT OR IGNORE INTO products(name,qty,min_qty,unit) VALUES(?,?,?,?)", row)
        c.commit()

def db_all():
    with db() as c:
        return c.execute(
            "SELECT id,name,qty,min_qty,unit FROM products ORDER BY qty ASC, name ASC"
        ).fetchall()

def db_get(pid):
    with db() as c:
        return c.execute(
            "SELECT id,name,qty,min_qty,unit FROM products WHERE id=?", (pid,)
        ).fetchone()

def db_set_qty(pid, qty):
    with db() as c:
        c.execute("UPDATE products SET qty=? WHERE id=?", (qty, pid)); c.commit()

def db_set_min(pid, mn):
    with db() as c:
        c.execute("UPDATE products SET min_qty=? WHERE id=?", (mn, pid)); c.commit()

def db_add(name, qty, mn, unit):
    try:
        with db() as c:
            c.execute("INSERT INTO products(name,qty,min_qty,unit) VALUES(?,?,?,?)",
                      (name, qty, mn, unit))
            c.commit()
        return True
    except sqlite3.IntegrityError:
        return False

def db_delete(pid):
    with db() as c:
        c.execute("DELETE FROM products WHERE id=?", (pid,)); c.commit()


# ══════════════ ФОРМАТИРОВАНИЕ ════════════════════════════════

def fq(v):
    return int(v) if float(v) == int(float(v)) else v

def zone(qty, mn):
    if qty == 0:       return "🔴"
    if qty < mn:       return "🟡"
    return "🟢"

def zone_label(qty, mn):
    if qty == 0:       return "нет"
    if qty < mn:       return f"мало (нужно ещё {fq(mn - qty)})"
    return "в норме"

def parse_num(text):
    try:
        v = float(text.strip().replace(",", "."))
        return v if v >= 0 else None
    except Exception:
        return None

def render_all(rows):
    if not rows:
        return "📦 *Список пуст*"

    green  = [(p,n,q,m,u) for p,n,q,m,u in rows if q >= m]
    yellow = [(p,n,q,m,u) for p,n,q,m,u in rows if 0 < q < m]
    red    = [(p,n,q,m,u) for p,n,q,m,u in rows if q == 0]

    lines = ["📦 *Все продукты:*"]

    if green:
        lines += ["", "🟢 *В норме:*"]
        for _,n,q,m,u in green:
            lines.append(f"  {n} — {fq(q)} {u} (норма: {fq(m)})")

    if yellow:
        lines += ["", "🟡 *Мало:*"]
        for _,n,q,m,u in yellow:
            lines.append(f"  {n} — {fq(q)} {u} (норма: {fq(m)}, нужно: {fq(m-q)})")

    if red:
        lines += ["", "🔴 *Нет в наличии:*"]
        for _,n,q,m,u in red:
            lines.append(f"  {n} ({u})")

    return "\n".join(lines)

def render_lacking(rows):
    red    = [(p,n,q,m,u) for p,n,q,m,u in rows if q == 0]
    yellow = [(p,n,q,m,u) for p,n,q,m,u in rows if 0 < q < m]

    if not red and not yellow:
        return "✅ *Всё в норме!* Нехватки нет."

    lines = ["⚠️ *Нужно пополнить:*"]
    if red:
        lines += ["", "🔴 *Нет совсем:*"]
        for _,n,q,m,u in red:
            lines.append(f"  {n} — купить {fq(m)} {u}")
    if yellow:
        lines += ["", "🟡 *Мало:*"]
        for _,n,q,m,u in yellow:
            lines.append(f"  {n} — есть {fq(q)} {u}, докупить {fq(m-q)} {u}")

    return "\n".join(lines)


# ══════════════ КЛАВИАТУРЫ ════════════════════════════════════

KB_MAIN = InlineKeyboardMarkup([
    [InlineKeyboardButton("📦 Все продукты",        callback_data="v:all"),
     InlineKeyboardButton("⚠️ Нехватка",            callback_data="v:lack")],
    [InlineKeyboardButton("✏️ Изменить количество", callback_data="l:edit"),
     InlineKeyboardButton("📐 Изменить норму",      callback_data="l:min")],
    [InlineKeyboardButton("➕ Добавить",            callback_data="add"),
     InlineKeyboardButton("🗑 Удалить",             callback_data="l:del")],
])

def kb_back():
    return InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Главное меню", callback_data="menu")]])

def kb_cancel():
    return InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Отмена", callback_data="menu")]])

def kb_products(rows, prefix):
    btns = [
        [InlineKeyboardButton(
            f"{zone(q,m)} {n} — {fq(q)}/{fq(m)} {u}",
            callback_data=f"{prefix}:{pid}"
        )]
        for pid, n, q, m, u in rows
    ]
    btns.append([InlineKeyboardButton("◀️ Назад", callback_data="menu")])
    return InlineKeyboardMarkup(btns)


# ══════════════ ХЭНДЛЕРЫ ═════════════════════════════════════

MENU_TEXT = "🛒 *Склад продуктов*\n\n🟢 норма  🟡 мало  🔴 нет\n\nВыберите действие:"

async def cmd_start(upd: Update, ctx: ContextTypes.DEFAULT_TYPE):
    ctx.user_data.clear()
    await upd.message.reply_text(MENU_TEXT, parse_mode="Markdown", reply_markup=KB_MAIN)
    return S_MENU


async def on_button(upd: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = upd.callback_query
    await q.answer()
    d = q.data

    if d == "menu":
        ctx.user_data.clear()
        await q.edit_message_text(MENU_TEXT, parse_mode="Markdown", reply_markup=KB_MAIN)
        return S_MENU

    if d == "v:all":
        await q.edit_message_text(
            render_all(db_all()), parse_mode="Markdown", reply_markup=kb_back())
        return S_MENU

    if d == "v:lack":
        await q.edit_message_text(
            render_lacking(db_all()), parse_mode="Markdown", reply_markup=kb_back())
        return S_MENU

    if d.startswith("l:"):
        action = d[2:]
        rows = db_all()
        if not rows:
            await q.edit_message_text("Список пуст.", reply_markup=kb_back())
            return S_MENU
        labels = {
            "edit": "✏️ *Выберите продукт — изменить количество:*",
            "min":  "📐 *Выберите продукт — изменить норму:*",
            "del":  "🗑 *Выберите продукт для удаления:*",
        }
        await q.edit_message_text(
            labels[action], parse_mode="Markdown",
            reply_markup=kb_products(rows, action))
        return S_MENU

    # Редактировать количество
    if d.startswith("edit:"):
        pid = int(d.split(":")[1])
        row = db_get(pid)
        if not row:
            await q.edit_message_text("Не найдено.", reply_markup=kb_back())
            return S_MENU
        ctx.user_data["edit_id"] = pid
        _, name, qty, mn, unit = row
        await q.edit_message_text(
            f"✏️ *{name}*\n"
            f"Сейчас: {fq(qty)} {unit}  {zone(qty,mn)} {zone_label(qty,mn)}\n"
            f"Норма: {fq(mn)} {unit}\n\n"
            f"Введите новое количество:",
            parse_mode="Markdown", reply_markup=kb_cancel())
        return S_EDIT_QTY

    # Редактировать норму
    if d.startswith("min:"):
        pid = int(d.split(":")[1])
        row = db_get(pid)
        if not row:
            await q.edit_message_text("Не найдено.", reply_markup=kb_back())
            return S_MENU
        ctx.user_data["min_id"] = pid
        _, name, qty, mn, unit = row
        await q.edit_message_text(
            f"📐 *{name}*\n"
            f"Текущая норма: {fq(mn)} {unit}\n"
            f"Количество сейчас: {fq(qty)} {unit}\n\n"
            f"Введите новую норму:",
            parse_mode="Markdown", reply_markup=kb_cancel())
        return S_EDIT_MIN

    # Удалить
    if d.startswith("del:"):
        pid = int(d.split(":")[1])
        row = db_get(pid)
        if row:
            db_delete(pid)
            await q.edit_message_text(
                f"🗑 *{row[1]}* удалён.", parse_mode="Markdown", reply_markup=kb_back())
        return S_MENU

    # Добавить
    if d == "add":
        ctx.user_data["new"] = {}
        await q.edit_message_text(
            "➕ *Добавление продукта*\n\n1️⃣ Введите *название:*",
            parse_mode="Markdown", reply_markup=kb_cancel())
        return S_ADD_NAME

    return S_MENU


async def got_edit_qty(upd: Update, ctx: ContextTypes.DEFAULT_TYPE):
    qty = parse_num(upd.message.text)
    if qty is None:
        await upd.message.reply_text("❌ Введите число ≥ 0 (например: 5 или 1.5):")
        return S_EDIT_QTY
    pid = ctx.user_data.pop("edit_id", None)
    row = db_get(pid)
    if not row:
        await upd.message.reply_text("Ошибка. /start"); return S_MENU
    db_set_qty(pid, qty)
    _, name, _, mn, unit = row
    await upd.message.reply_text(
        f"{zone(qty,mn)} *{name}*: {fq(qty)} {unit} — {zone_label(qty,mn)}",
        parse_mode="Markdown", reply_markup=KB_MAIN)
    return S_MENU


async def got_edit_min(upd: Update, ctx: ContextTypes.DEFAULT_TYPE):
    mn = parse_num(upd.message.text)
    if mn is None:
        await upd.message.reply_text("❌ Введите число ≥ 0:")
        return S_EDIT_MIN
    pid = ctx.user_data.pop("min_id", None)
    row = db_get(pid)
    if not row:
        await upd.message.reply_text("Ошибка. /start"); return S_MENU
    db_set_min(pid, mn)
    _, name, qty, _, unit = row
    await upd.message.reply_text(
        f"📐 *{name}*: норма = {fq(mn)} {unit}  {zone(qty,mn)} {zone_label(qty,mn)}",
        parse_mode="Markdown", reply_markup=KB_MAIN)
    return S_MENU


async def got_add_name(upd: Update, ctx: ContextTypes.DEFAULT_TYPE):
    name = upd.message.text.strip()
    if not name:
        await upd.message.reply_text("Введите название:"); return S_ADD_NAME
    ctx.user_data["new"]["name"] = name
    await upd.message.reply_text(
        f"2️⃣ *{name}*\nВведите текущее *количество* (0 = нет в наличии):",
        parse_mode="Markdown")
    return S_ADD_QTY


async def got_add_qty(upd: Update, ctx: ContextTypes.DEFAULT_TYPE):
    qty = parse_num(upd.message.text)
    if qty is None:
        await upd.message.reply_text("❌ Введите число ≥ 0:"); return S_ADD_QTY
    ctx.user_data["new"]["qty"] = qty
    await upd.message.reply_text(
        "3️⃣ Введите *норму* (минимальное нужное количество):",
        parse_mode="Markdown")
    return S_ADD_MIN


async def got_add_min(upd: Update, ctx: ContextTypes.DEFAULT_TYPE):
    mn = parse_num(upd.message.text)
    if mn is None:
        await upd.message.reply_text("❌ Введите число ≥ 0:"); return S_ADD_MIN
    ctx.user_data["new"]["min_qty"] = mn
    await upd.message.reply_text(
        "4️⃣ Введите *единицу измерения* (шт, кг, л, г, пач …):",
        parse_mode="Markdown")
    return S_ADD_UNIT


async def got_add_unit(upd: Update, ctx: ContextTypes.DEFAULT_TYPE):
    unit = upd.message.text.strip() or "шт"
    d    = ctx.user_data.pop("new", {})
    name = d.get("name", "")
    qty  = d.get("qty", 0)
    mn   = d.get("min_qty", 1)
    if db_add(name, qty, mn, unit):
        await upd.message.reply_text(
            f"✅ Добавлен: {zone(qty,mn)} *{name}* — {fq(qty)}/{fq(mn)} {unit}\n"
            f"Статус: {zone_label(qty,mn)}",
            parse_mode="Markdown", reply_markup=KB_MAIN)
    else:
        await upd.message.reply_text(
            f"❌ *{name}* уже существует.", parse_mode="Markdown", reply_markup=KB_MAIN)
    return S_MENU


# ══════════════ ЗАПУСК ════════════════════════════════════════

def main():
    db_init()
    print("✅ База данных готова")
    app = Application.builder().token(BOT_TOKEN).build()
    conv = ConversationHandler(
        entry_points=[CommandHandler("start", cmd_start)],
        states={
            S_MENU:     [CallbackQueryHandler(on_button)],
            S_EDIT_QTY: [MessageHandler(filters.TEXT & ~filters.COMMAND, got_edit_qty),
                         CallbackQueryHandler(on_button)],
            S_EDIT_MIN: [MessageHandler(filters.TEXT & ~filters.COMMAND, got_edit_min),
                         CallbackQueryHandler(on_button)],
            S_ADD_NAME: [MessageHandler(filters.TEXT & ~filters.COMMAND, got_add_name),
                         CallbackQueryHandler(on_button)],
            S_ADD_QTY:  [MessageHandler(filters.TEXT & ~filters.COMMAND, got_add_qty),
                         CallbackQueryHandler(on_button)],
            S_ADD_MIN:  [MessageHandler(filters.TEXT & ~filters.COMMAND, got_add_min),
                         CallbackQueryHandler(on_button)],
            S_ADD_UNIT: [MessageHandler(filters.TEXT & ~filters.COMMAND, got_add_unit),
                         CallbackQueryHandler(on_button)],
        },
        fallbacks=[CommandHandler("start", cmd_start)],
        per_message=False,
        allow_reentry=True,
    )
    app.add_handler(conv)
    print("🤖 Бот запущен. Ctrl+C — остановить.\n")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
