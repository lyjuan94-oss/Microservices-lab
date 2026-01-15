package com.skistation.reservationms.repository;

import com.skistation.reservationms.entities.Reservation;
import org.springframework.data.repository.CrudRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface IReservationRepository extends CrudRepository<Reservation, Long> {

}
