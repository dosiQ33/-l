"""
Функции для обучения и прогнозирования CLTV моделей с двумя сегментами
"""

import numpy as np
import pandas as pd
from collections import defaultdict, deque
from sklearn.metrics import mean_absolute_error


def fit_all_segments_improved(segmented_model, df, features, target_col='TARGET_NEXT_MARGIN',
                              validation_cutoff='2025-03-31', categorical_features=None):
    """
    Обучение моделей для всех сегментов

    Args:
        segmented_model: Объект ImprovedSegmentedCLTV
        df: DataFrame с обучающими данными
        features: Список фич для обучения
        target_col: Название таргета
        validation_cutoff: Дата разделения train/val
        categorical_features: Список категориальных признаков

    Returns:
        dict: Результаты обучения для каждого сегмента
    """

    segment_stats, large_segments, small_segments = segmented_model.analyze_segment_distribution(df)

    print(f"\nНачинаем обучение...")
    results = {}

    # Большие сегменты
    for segment_id in large_segments:
        print(f"\n{'='*60}")
        print(f"Сегмент {segment_id}")
        print(f"{'='*60}")

        try:
            X_train, y_train, X_val, y_val, y_val_orig, segment_data = \
                segmented_model.prepare_segment_data(df, segment_id, features, target_col, validation_cutoff)

            if len(X_train) < 100:
                print(f"  Недостаточно данных: {len(X_train)}")
                continue

            model, quantile_models, metrics = segmented_model.train_segment_model(
                segment_id, X_train, y_train, X_val, y_val, categorical_features
            )

            segmented_model.models[segment_id] = model
            segmented_model.quantile_models[segment_id] = quantile_models
            segmented_model.segment_stats[segment_id] = metrics
            segmented_model.feature_importance[segment_id] = metrics['feature_importance']

            print(f"\n  Результаты:")
            print(f"    R² train: {metrics['train_r2']:.3f}, R² val: {metrics['val_r2']:.3f}")
            print(f"    MAE val: {metrics['val_mae']:.3f}")
            print(f"    Samples: {metrics['train_samples']:,} / {metrics['val_samples']:,}")

            print(f"    Бизнес метрики:")
            for metric_name, value in metrics['business_metrics'].items():
                print(f"      {metric_name}: {value:.3f}")

            results[segment_id] = metrics

        except Exception as e:
            print(f"  Ошибка: {e}")
            import traceback
            traceback.print_exc()
            continue

    # Fallback для малых сегментов (если есть)
    if small_segments:
        print(f"\n{'='*60}")
        print(f"Fallback для малых сегментов: {small_segments}")
        print(f"{'='*60}")

        small_segments_data = df[df['SEGMENT_ID'].isin(small_segments)].copy()

        if len(small_segments_data) >= 500:
            try:
                from cltv_utils import stabilize_target  # предполагается, что функция определена

                small_segments_data['target_stable'] = stabilize_target(small_segments_data[target_col])

                train_mask = pd.to_datetime(small_segments_data['MONTH_END']) <= pd.to_datetime(validation_cutoff)
                val_mask = ~train_mask

                X_train_fb = small_segments_data[train_mask][features]
                y_train_fb = small_segments_data[train_mask]['target_stable']
                X_val_fb = small_segments_data[val_mask][features]
                y_val_fb = small_segments_data[val_mask]['target_stable']

                model_fb, quantile_models_fb, metrics_fb = segmented_model.train_segment_model(
                    'FALLBACK', X_train_fb, y_train_fb, X_val_fb, y_val_fb, categorical_features
                )

                segmented_model.models['FALLBACK'] = model_fb
                segmented_model.quantile_models['FALLBACK'] = quantile_models_fb
                segmented_model.segment_stats['FALLBACK'] = metrics_fb

                for seg_id in small_segments:
                    segmented_model.fallback_segments[seg_id] = 'FALLBACK'

                print(f"  Fallback R² val: {metrics_fb['val_r2']:.3f}")

            except Exception as e:
                print(f"  Ошибка fallback: {e}")

    return results


def calculate_rolling_features(history, feature_name):
    """Расчет rolling фич"""
    hist_array = np.array(list(history))
    if len(hist_array) == 0:
        return 0.0

    if feature_name.startswith('avg_'):
        window_map = {'1m': 1, '2m': 2, '3m': 3, '6m': 6, '12m': 12}
        window = min(window_map.get(feature_name.split('_')[-1], len(hist_array)), len(hist_array))
        return np.mean(hist_array[-window:]) if window > 0 else 0.0

    elif feature_name == 'stddev_12m':
        window = min(12, len(hist_array))
        return np.std(hist_array[-window:]) if window > 1 else 0.0

    elif feature_name == 'growth_rate_3m':
        if len(hist_array) >= 6:
            recent_avg = np.mean(hist_array[-2:])
            older_avg = np.mean(hist_array[-6:-3])
            if abs(older_avg) > 1e-6:
                return (recent_avg - older_avg) / abs(older_avg)
        return 0.0

    return 0.0


def update_client_state(state, client_id, predicted_margin, month_index):
    """Обновление состояния клиента"""
    client_state = state[client_id]
    client_state['lag3'] = client_state['lag2']
    client_state['lag2'] = client_state['lag1']
    client_state['lag1'] = predicted_margin
    client_state['history'].append(predicted_margin)


def initialize_client_state(prod_data, forecast_start):
    """Инициализация состояния клиентов"""
    state = {}
    for _, row in prod_data.iterrows():
        client_id = int(row['CLIENT_ID'])
        hist = deque(maxlen=12)
        for lag_col in ['MARGIN_LAG3', 'MARGIN_LAG2', 'MARGIN_LAG1', 'MARGIN']:
            if lag_col in row.index and pd.notna(row[lag_col]):
                hist.append(float(row[lag_col]))

        if len(hist) == 0:
            hist.append(float(row['MARGIN']))

        state[client_id] = {
            'segment_id': str(row['SEGMENT_ID']),
            'forecast_start': pd.to_datetime(forecast_start),
            'lag1': row['MARGIN'],
            'lag2': row.get('MARGIN_LAG1', 0.0),
            'lag3': row.get('MARGIN_LAG2', 0.0),
            'history': hist,
            'cumulative_survival': 1.0,
            'base_tenure': row.get('TENURE_MONTHS', 1),
            'quality_code': str(row.get('QUALITY_CODE', 'UNKNOWN')),
            'subject_kind_id': str(row.get('SUBJECT_KIND_ID', 'UNKNOWN')),
            'ec_sector_id': str(row.get('EC_SECTOR_ID', 'UNKNOWN')),
        }
    return state


def improved_recursive_forecasting(segmented_model_obj, prod_data, churn_map,
                                  horizon_months=6, forecast_start="2025-09-30",
                                  include_uncertainty=True, discount_rate_annual=0.12):
    """
    Рекурсивное прогнозирование с учетом churn и дисконтирования

    Args:
        segmented_model_obj: Обученная модель ImprovedSegmentedCLTV
        prod_data: DataFrame с продакшн данными
        churn_map: Словарь {client_id: churn_info}
        horizon_months: Горизонт прогноза в месяцах
        forecast_start: Дата начала прогноза
        include_uncertainty: Включать ли неопределенность
        discount_rate_annual: Годовая ставка дисконтирования

    Returns:
        pd.DataFrame: Прогнозы для каждого клиента по месяцам
    """
    from dateutil.relativedelta import relativedelta

    def calculate_survival_probability(client_id, churn_map):
        if client_id not in churn_map:
            return 1.0
        return np.exp(-churn_map[client_id]['monthly_hazard'])

    def discounted(value, months, annual_rate):
        if annual_rate <= 0:
            return value
        monthly_rate = (1 + annual_rate) ** (1/12) - 1
        return value / ((1 + monthly_rate) ** months)

    # Фильтрация данных только для клиентов с churn
    prod_with_churn = prod_data[prod_data['CLIENT_ID'].isin(churn_map.keys())].copy()

    print(f"Данные для прогнозирования:")
    print(f"  Всего: {len(prod_data):,}")
    print(f"  С churn: {len(prod_with_churn):,}")

    client_state = initialize_client_state(prod_with_churn, forecast_start)
    start_month_end = pd.to_datetime(forecast_start)
    forecast_records = []

    print(f"\nПрогноз на {horizon_months} месяцев...")

    for month_idx in range(1, horizon_months + 1):
        if month_idx % 2 == 1:
            print(f"Месяц {month_idx}/{horizon_months}")

        current_month_end = start_month_end + relativedelta(months=month_idx-1)
        month_of_year = current_month_end.month
        quarter_of_year = ((current_month_end.month - 1) // 3) + 1

        clients_by_segment = defaultdict(list)
        client_features_by_segment = defaultdict(list)

        for client_id, state in client_state.items():
            segment_id = state['segment_id']

            features = {
                'SEGMENT_ID': str(segment_id),
                'MARGIN': state['lag1'],
                'MARGIN_LAG1': state['lag1'],
                'MARGIN_LAG2': state['lag2'],
                'MARGIN_LAG3': state['lag3'],
                'MARGIN_AVG_1M_LAG': calculate_rolling_features(state['history'], 'avg_1m'),
                'MARGIN_AVG_2M_LAG': calculate_rolling_features(state['history'], 'avg_2m'),
                'MARGIN_AVG_3M_LAG': calculate_rolling_features(state['history'], 'avg_3m'),
                'MARGIN_AVG_6M_LAG': calculate_rolling_features(state['history'], 'avg_6m'),
                'MARGIN_AVG_12M_LAG': calculate_rolling_features(state['history'], 'avg_12m'),
                'MARGIN_STDDEV_12M_LAG': calculate_rolling_features(state['history'], 'stddev_12m'),
                'MARGIN_GROWTH_RATE_3M': calculate_rolling_features(state['history'], 'growth_rate_3m'),
                'MONTH_OF_YEAR': month_of_year,
                'QUARTER_OF_YEAR': quarter_of_year,
                'TENURE_MONTHS': state['base_tenure'] + month_idx,
                'QUALITY_CODE': state['quality_code'],
                'SUBJECT_KIND_ID': state['subject_kind_id'],
                'EC_SECTOR_ID': state['ec_sector_id'],
            }

            clients_by_segment[segment_id].append(client_id)
            client_features_by_segment[segment_id].append(features)

        all_predictions = {}
        all_uncertainty = {}

        for segment_id, client_ids in clients_by_segment.items():
            if not client_ids:
                continue

            segment_features_df = pd.DataFrame(client_features_by_segment[segment_id])

            try:
                if include_uncertainty:
                    pred_result = segmented_model_obj.predict_segment(
                        segment_id, segment_features_df,
                        return_stable=False, return_uncertainty=True
                    )

                    for i, client_id in enumerate(client_ids):
                        all_predictions[client_id] = pred_result['prediction'][i]
                        all_uncertainty[client_id] = {
                            'lower': pred_result['lower_bound'][i],
                            'median': pred_result['median'][i],
                            'upper': pred_result['upper_bound'][i]
                        }
                else:
                    segment_predictions = segmented_model_obj.predict_segment(
                        segment_id, segment_features_df, return_stable=False
                    )
                    for i, client_id in enumerate(client_ids):
                        all_predictions[client_id] = segment_predictions[i]

            except Exception as e:
                print(f"Ошибка {segment_id}: {e}")
                avg_margin = np.mean([state['lag1'] for state in client_state.values()
                                    if state['segment_id'] == segment_id])
                for client_id in client_ids:
                    all_predictions[client_id] = avg_margin

        for client_id, predicted_margin in all_predictions.items():
            monthly_survival = calculate_survival_probability(client_id, churn_map)
            client_state[client_id]['cumulative_survival'] *= monthly_survival

            margin_with_survival = predicted_margin * client_state[client_id]['cumulative_survival']
            margin_discounted = discounted(margin_with_survival, month_idx, discount_rate_annual)

            record = {
                'CLIENT_ID': client_id,
                'SEGMENT_ID': client_state[client_id]['segment_id'],
                'FORECAST_MONTH_END': current_month_end.strftime('%Y-%m-%d'),
                'MONTH_INDEX': month_idx,
                'PRED_MARGIN_RAW': float(predicted_margin),
                'MONTHLY_SURVIVAL': float(monthly_survival),
                'CUM_SURVIVAL': float(client_state[client_id]['cumulative_survival']),
                'PRED_MARGIN_SURV': float(margin_with_survival),
                'PRED_MARGIN_SURV_DISCOUNTED': float(margin_discounted)
            }

            if include_uncertainty and client_id in all_uncertainty:
                unc = all_uncertainty[client_id]
                record['PRED_LOWER_BOUND'] = float(unc['lower'] * client_state[client_id]['cumulative_survival'])
                record['PRED_UPPER_BOUND'] = float(unc['upper'] * client_state[client_id]['cumulative_survival'])

            forecast_records.append(record)
            update_client_state(client_state, client_id, predicted_margin, month_idx)

    print(f"Завершено: {len(forecast_records):,} записей")
    return pd.DataFrame(forecast_records)
