package com.synki.temperatura_monitoring.domain.repository;

import com.synki.temperatura_monitoring.domain.model.AlertEvent;
import com.synki.temperatura_monitoring.domain.model.SensorId;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

public interface AlertEventRepository extends JpaRepository<AlertEvent, com.synki.temperatura_monitoring.domain.model.AlertEventId> {

    Page<AlertEvent> findAllBySensorId(SensorId sensorId, Pageable pageable);
}
