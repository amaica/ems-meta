package com.synki.temperatura_monitoring.domain.repository;

import com.synki.temperatura_monitoring.domain.model.SensorAlert;
import com.synki.temperatura_monitoring.domain.model.SensorId;
import com.synki.temperatura_monitoring.domain.model.SensorMonitoring;
import org.springframework.data.jpa.repository.JpaRepository;

public interface SensorAlertRepository extends JpaRepository<SensorAlert, SensorId> {
}
