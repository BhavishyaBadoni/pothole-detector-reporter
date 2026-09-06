import pandas as pd
import numpy as np
from sklearn.ensemble import GradientBoostingRegressor
import joblib

def generate_dummy_data(n_samples=1000):
    np.random.seed(42)
    
    # Generate random features
    peak_jerk = np.random.uniform(2.0, 15.0, n_samples)
    dsr = np.random.uniform(0.1, 5.0, n_samples)
    r_gyro = np.random.uniform(0.5, 8.0, n_samples)
    
    # Generate synthetic severity based on features (some formula + noise)
    # Target range ~ 1.0 to 10.0
    base_severity = (peak_jerk * 0.4) + (dsr * 0.3) + (r_gyro * 0.2)
    noise = np.random.normal(0, 0.5, n_samples)
    severity = np.clip(base_severity + noise, 1.0, 10.0)
    
    df = pd.DataFrame({
        'PeakJerk': peak_jerk,
        'DSR': dsr,
        'R_gyro': r_gyro,
        'Severity': severity
    })
    
    return df

def train_and_save():
    print("Generating dummy data...")
    df = generate_dummy_data()
    
    X = df[['PeakJerk', 'DSR', 'R_gyro']]
    y = df['Severity']
    
    print("Training GradientBoostingRegressor...")
    model = GradientBoostingRegressor(n_estimators=100, random_state=42)
    model.fit(X, y)
    
    print("Saving model to severity_model.pkl...")
    joblib.dump(model, 'severity_model.pkl')
    print("Model saved successfully.")

if __name__ == "__main__":
    train_and_save()
