# CLTV Моделирование с двумя сегментами

## Описание изменений

Созданы два новых notebook для работы с данными и моделированием CLTV с объединенными сегментами.

### Объединение сегментов

Теперь вместо 5-6 оригинальных сегментов используются только 2:

- **small**: объединение сегментов 1026 (MICRO) + 1027 (SMALL) + 1040
- **large_and_middle**: объединение сегментов 1022 (MIDDLE) + 1023 (LARGE)

## Workflow

### Шаг 1: Загрузка данных из CSV и сохранение в Parquet

Notebook: `data_loader.ipynb`

**Что делает:**
- Загружает CSV файлы с обучающими данными, продакшн снэпшотом и churn данными
- Обрабатывает различные форматы CSV (разные разделители, кодировки)
- Сохраняет все данные в формате Parquet для быстрой загрузки

**Требуемые файлы:**
- `CLTV_UL_TRAIN_MART.csv`
- `CLTV_UL_PROD_SNAPSHOT.csv`
- `../churn_result_msb.csv`

**Выходные файлы:**
- `data/train_data.parquet`
- `data/prod_data.parquet`
- `data/churn_data.parquet`

**Как запустить:**
```bash
jupyter notebook data_loader.ipynb
# Запустите все ячейки (Cell -> Run All)
```

### Шаг 2: Обучение моделей и прогнозирование

Notebook: `Optuna CLTV - 2 Segments.ipynb`

**Что делает:**
1. Загружает данные из Parquet файлов
2. Объединяет оригинальные сегменты в два новых (small и large_and_middle)
3. Обучает модели CatBoost для каждого сегмента с оптимизацией гиперпараметров через Optuna
4. Делает прогнозы с учетом churn и дисконтирования
5. Рассчитывает CLTV для каждого клиента

**Конфигурация:**

В ячейке с классом `Config` можно настроить:
- `OPTUNA_TRIALS` - количество trials для оптимизации (по умолчанию 10)
- `HORIZON_MONTHS` - горизонт прогнозирования (по умолчанию 6)
- `FORECAST_START` - дата начала прогноза
- `TRAIN_QUANTILES` - обучать ли квантильные модели (по умолчанию False)

**Как запустить:**
```bash
jupyter notebook "Optuna CLTV - 2 Segments.ipynb"
# Запустите все ячейки (Cell -> Run All)
```

## Структура файлов

```
project/
├── data_loader.ipynb                      # Notebook для загрузки CSV → Parquet
├── Optuna CLTV - 2 Segments.ipynb        # Основной notebook с обучением
├── Optuna CLTV.ipynb                      # Оригинальный notebook (для справки)
├── data/                                  # Директория с Parquet файлами
│   ├── train_data.parquet
│   ├── prod_data.parquet
│   └── churn_data.parquet
└── models/                                # Директория с сохраненными моделями
    └── YYYYMMDD_HHMMSS/                   # Папка с версией модели
        ├── model_seg_small.cbm
        ├── model_seg_large_and_middle.cbm
        ├── metadata.json
        ├── cltv_forecast_detailed.csv
        └── cltv_summary.csv
```

## Выходные данные

После выполнения notebook создаются следующие файлы:

1. **cltv_forecast_detailed.csv** - детальный прогноз по месяцам для каждого клиента
   - CLIENT_ID
   - SEGMENT_ID (small/large_and_middle)
   - FORECAST_MONTH_END
   - MONTH_INDEX
   - PRED_MARGIN_RAW
   - MONTHLY_SURVIVAL
   - CUM_SURVIVAL
   - PRED_MARGIN_SURV
   - PRED_MARGIN_SURV_DISCOUNTED

2. **cltv_summary.csv** - агрегированный CLTV (одна строка на клиента)
   - CLIENT_ID
   - SEGMENT_ID
   - CLTV_12M (дисконтированный CLTV с учетом churn)
   - CLTV_12M_NO_DISCOUNT
   - CLTV_12M_RAW
   - CLTV_Category (Убыточный/Низкий/Средний/Высокий/Премиальный)

## Преимущества двух сегментов

1. **Более устойчивое моделирование**: больше данных в каждом сегменте
2. **Лучшая обобщающая способность**: модели менее подвержены переобучению
3. **Упрощенное управление**: проще поддерживать 2 модели вместо 5-6
4. **Бизнес-осмысленность**: четкое разделение на малый и крупный/средний бизнес

## Маппинг сегментов

| Оригинальный сегмент | Название | Новый сегмент      |
|---------------------|----------|-------------------|
| 1026                | MICRO    | small             |
| 1027                | SMALL    | small             |
| 1040                | -        | small             |
| 1022                | MIDDLE   | large_and_middle  |
| 1023                | LARGE    | large_and_middle  |

## Примечания

- Все данные предобрабатываются перед обучением (заполнение пропусков, стабилизация таргета)
- Модели обучаются с time-series split для валидации
- Используется оптимизация гиперпараметров через Optuna
- Прогнозы учитывают churn вероятность и дисконтирование

## Troubleshooting

**Проблема**: "Файлы не найдены" при запуске основного notebook

**Решение**: Сначала запустите `data_loader.ipynb` чтобы создать Parquet файлы

---

**Проблема**: Долгое обучение моделей

**Решение**: Уменьшите `Config.OPTUNA_TRIALS` с 10 до 5 или установите `use_optuna=False` в конструкторе ImprovedSegmentedCLTV

---

**Проблема**: Недостаточно памяти

**Решение**: Обрабатывайте данные частями или уменьшите `Config.HORIZON_MONTHS`
